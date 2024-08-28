require 'open3'
require 'tap_parser'
require 'digest'
require 'audit'
require 'headless'

# NOTE: This is an utter hack, designed to work around an infelicity in
# the Headless implementation: if Xvfb claims it's running on some port but
# is refusing connections, then Headless::ensure_xvfb_launched will abort with
# an exception, even if other displays are potentially available.
# This monkey-patch implements https://github.com/leonid-shevtsov/headless/issues/100
# and hopefully can be removed one day...
class Headless
  private
  def pick_available_display(display_set, can_reuse)
    @error = nil
    display_set.each do |display_number|
      @display = display_number

      return true if xvfb_running? && can_reuse && (xvfb_mine? || !@autopick_display)
      begin
        return true if !xvfb_running? && launch_xvfb
      rescue Headless::Exception => e
        @error = e
      end
    end
    raise @error || Headless::Exception.new("Could not find an available display")
  end
end


class Grader < ApplicationRecord
  DEFAULT_COMPILE_TIMEOUT = 60
  DEFAULT_GRADING_TIMEOUT = 300
  DEFAULT_TEST_TIMEOUT    = 10
  DEFAULT_ERRORS_TO_SHOW   = 3
  class GradingJob
    # This job class helps keeps track of all jobs that go into the beanstalk system
    # It keeps track of starting times for them, and the arguments passed in.
    # It prunes dead jobs every now and then (250jobs, by default), or whenever
    # the status page is visited.
    # Change this one job class to change the integration with beanstalk.
    include Backburner::Queue
    # With a Postgres connection limit of 100, and a pool size of 5,
    # this needs to stay low enough to leave some headroom, and 5 * 15 == 75 < 100
    queue_jobs_limit 15
    def self.enqueue(grader, assn, sub, opts = {})
      job = Backburner::Worker.enqueue GradingJob, [grader.id, assn.id, sub.id], opts

      Grader.delayed_grades[job[:id]] = {
        start_time: Time.current,
        grader_type: grader.display_type,
        user_name: sub.user.display_name,
        course: assn.course.id,
        assn: assn.id,
        sub: sub.id,
        opts: opts
      }
      job[:id]
    end
    def self.perform(grader_id, assn_id, sub_id)
      Grader.find(grader_id).grade_sync!(Assignment.find(assn_id), Submission.find(sub_id))
    end

    def self.prune(threshold = 250)
      begin
        job_ids = Grader.delayed_grades.keys
        return if job_ids.count < threshold
        bean = Backburner::Connection.new(Backburner.configuration.beanstalk_url)
        job_ids.each do |k|
          job = bean.jobs.find(k)
          if job.nil?
            Grader.delayed_grades.delete k
          elsif job.stats["state"] == "buried"
            Grader.delayed_grades.delete k
            job.delete
          end
        end
      rescue
        # nothing to do
      ensure
        bean.close if bean
      end
    end
    def self.clear_all!
      begin
        count = 0
        bean = Backburner::Connection.new(Backburner.configuration.beanstalk_url)
        bean.tubes.each do |tube|
          [:ready, :delayed, :buried].each do |status|
            while tube.peek(status)
              tube.peek(status).delete
              count += 1
            end
          end
        end
        Grader.delayed_grades.clear
        return count
      rescue Exception => e
        return "Error clearing queue: #{e}"
      ensure
        bean.close if bean
      end
    end
  end

  belongs_to :assignment
  belongs_to :upload, optional: true
  belongs_to :extra_upload, class_name: 'Upload', optional: true

  has_many :grades
  validates :assignment, presence: true
  validates :order, presence: true, uniqueness: {scope: :assignment_id}
  before_save :recompute_grades, if: :avail_score_changed?
  before_save :save_uploads

  after_create :send_build_request_to_orca

  include GradersHelper

  class << self
    attr_accessor :delayed_grades
    attr_accessor :delayed_count
  end

  @delayed_grades = {}
  @delayed_count = 0

  def self.delayed_grades
    @delayed_grades
  end
  def self.delayed_count
    @delayed_count
  end

  def self.orca_config
    YAML.load(File.open(Rails.root.join('config/orca.yml')))
  end

  def self.path_to_grader_secret?(path)
    %r{/graders/[0-9]+/.*\.secret$}.match?(path)
  end

  def valid_orca_secret?(secret, grade)
    secret_path = orca_secret_path(grade)
    return false unless File.exist? secret_path

    File.open(secret_path) do |f|
      return secret == f.read
    end
  end

  def orca_secret_for(grade)
    return nil unless File.exist? orca_secret_path(grade)
    File.read orca_secret_path(grade)
  end

  def orca_secret_path(grade)
    File.join(grade.submission_grader_dir, 'orca.secret')
  end

  def orca_job_status_path(grade)
    File.join(grade.submission_grader_dir, 'job_status.json')
  end

  def orca_job_status_url
    "#{Grader::orca_config["site_url"][Rails.env]}/api/v1/grader_images/status/#{dockerfile_sha_sum}  "
  end
  
  def orca_job_status_for(grade)
    return nil unless File.exist? orca_job_status_path(grade)
    JSON.parse(File.read(orca_job_status_path(grade)))
  end

  def save_orca_job_status(grade, status)
    File.open(orca_job_status_path(grade), 'w') do |f|
      f.write JSON.generate(status)
    end
  end

  private

  def build_result_status(status)
    return 'Unknown' if status.nil?
    
    if status['completed'] && status['successful']
      'Completed'
    elsif status['completed'] && !status['successful']
      'Failed'
    elsif !status['completed']
      'Pending'
    else
      'Unknown'
    end
  end
  public
  
  def orca_current_build_result_status
    build_result_status(self.orca_status.dig('current_build'))
  end
  def orca_last_build_result_status
    build_result_status(self.orca_status.dig('last_build'))
  end
  def orca_current_build_time
    self.orca_status.dig('current_build', 'build_time')
  end
  def orca_last_build_time
    self.orca_status.dig('last_build', 'build_time')
  end
  def latest_build_logs
    self.orca_status.dig('current_build', 'logs') || self.orca_status.dig('last_build', 'logs')
  end

  def generate_grading_job(sub)
    fail NotImplementedError, "Graders who send jobs to Orca should implement this method."
  end

  def generate_metadata_table(sub)
    ans = {}
    if sub.team
      ans["display_name"] = sub.team.member_names
      ans["id"] = sub.team_id.to_s
      ans["user_or_team"] = "team"
    else
      ans["display_name"] = sub.user.display_name
      ans["id"] = sub.user_id.to_s
      ans["user_or_team"] = "user"
    end
    ans
  end

  # Needed because when Cocoon instantiates new graders, it doesn't know what
  # subtype they are, yet
  def test_class
    @test_class
  end
  def test_class=(value)
    params_will_change! if test_class != value
    @test_class = value
  end
  def errors_to_show
    @errors_to_show
  end
  def errors_to_show=(value)
    params_will_change! if errors_to_show != value
    @errors_to_show = value
  end
  def test_timeout
    @test_timeout
  end
  def test_timeout=(value)
    params_will_change! if test_timeout != value
    @test_timeout = value
  end
  def self.default_line_length
    102
  end
  def line_length
    (@line_length || Grader.default_line_length).to_i
  end
  def line_length=(value)
    params_will_change! if line_length != value
    @line_length = value
  end

  # Needed to make the upload not be anonymous
  attr_accessor :upload_by_user_id

  def self.unique
    select(column_names - ["id"]).distinct
  end

  # NOTE: These two methods may be overridden if a single grader contains
  # both regular and E.C. weight
  def normal_weight
    if self.extra_credit
      0.0
    else
      self.avail_score.to_f
    end
  end

  def extra_credit_weight
    if self.extra_credit
      self.avail_score.to_f
    else
      0.0
    end
  end

  def grade_sync!(assignment, submission)
    send_grading_request_to_orca(assignment, submission) if self.orca_status
    
    ans = do_grading(assignment, submission)
    submission.compute_grade! if submission.grade_complete?
    ans
  end

  def grade(assignment, submission, prio = 0)
    if autograde?
      GradingJob.enqueue self, assignment, submission, prio: 1000 + prio, ttr: 1200
    else
      grade_sync!(assignment, submission)
    end
  end

  def autograde?
    false
  end

  def autograde!(assignment, submission, prio = 0)
    if autograde?
      grade(assignment, submission, prio)
    end
  end

  def grade_exists_for(sub)
    !Grade.find_by(grader_id: self.id, submission_id: sub.id).nil?
  end

  def ensure_grade_exists_for!(sub)
    g = grade_for(sub, true)
    if g.new_record?
      g.save
      true
    else
      false
    end
  end

  def guess_who_graded(sub)
    nil
  end

  def upload_file
    if @upload_data
      @upload_data.original_filename
    elsif self.upload
      self.upload.file_name
    else
      nil
    end
  end

  def extra_upload_file
    self.extra_upload&.file_name
  end

  def upload_file=(data)
    if data.nil?
      errors.add(:base, "You need to submit a file.")
      return
    end

    up = Upload.new
    up.user = User.find_by(id: self.upload_by_user_id)
    up.assignment = assignment
    up.upload_data = data
    up.metadata = {
      type: "#{type} Configuration",
      date: Time.current.strftime("%Y/%b/%d %H:%M:%S %Z"),
      mimetype: data.content_type,
      prof_override: {file_count: true, file_size: true}
    }
    self.upload = up
    self.upload_id_will_change!
  end

  def extra_upload_file=(data)
    if data.nil?
      return
    end

    up = Upload.new
    up.user = User.find_by(id: self.upload_by_user_id)
    up.assignment = assignment
    up.upload_data = data
    up.metadata = {
      type: "#{type} Extra Configuration",
      date: Time.current.strftime("%Y/%b/%d %H:%M:%S %Z"),
      mimetype: data.content_type,
      prof_override: {file_count: true, file_size: true}
    }
    self.extra_upload = up
    self.extra_upload_id_will_change!
  end

  def assign_attributes(attrs)
    if attrs[:removefile] == "remove"
      self.upload = nil
    end
    attrs.delete :removefile
    if attrs[:orca_status]
      self.orca_status = self.orca_status || {
        current_build: {completed: false, successful: false, build_time: DateTime.now}
      }
      attrs.delete :orca_status
    end
    self.upload_by_user_id = attrs[:upload_by_user_id]
    self.assignment = attrs[:assignment] if self.assignment.nil? && attrs[:assignment]
    super(attrs)
  end

  def export_data
    # Export all the data from this grader
    fail NotImplementedError, "Each grader should implement this"
  end

  def export_data_schema
    # Describe the format for export_data
    # Return either and html_safe? string, or the name of a partial
    fail NotImplementedError, "Each grader should implement this"
  end

  def import_data
    # Import all the data (in the same format as produced by export_data)
    fail NotImplementedError, "Each grader should implement this"
  end

  def import_data_schema
    # Describe the format for import_data
    # Return either and html_safe? string, or the name of a partial
    fail NotImplementedError, "Each grader should implement this"
  end

  def check_for_malformed_submission(upload)
    []
  end


  # Note: this needs to be public since it's used from the GradersController
  def send_build_request_to_orca
    return unless self.orca_status
    
    Thread.new do
      begin
        os = self.orca_status
        os['last_build'] = os['current_build']
        os['current_build'] = { completed: false, successful: false, build_time: DateTime.now }
        self.update(orca_status: os)
        orca_url = Grader.orca_config['site_url'][Rails.env]
        body, status_code = post_image_request_with_retry(
          URI.parse("#{orca_url}/api/v1/grader_images"),
          orca_image_build_config
        )
        if body['errors'].blank?
          message = body['message']
        else
          message = "Encountered the following errors when pushing image build to Orca:\n"
          message << body['errors'].join("\n")
        end
        unless (message == "OK" && status_code == 200)
          handle_image_build_attempt [message], (status_code == 200)
        end
      rescue StandardError => e
        handle_image_build_attempt [e.message], false
      end
    end
  end

  def handle_image_build_attempt(logs, successful)
    os = self.orca_status
    os['current_build'] = {
      completed: true,
      successful: successful,
      logs: logs,
      build_time: DateTime.now
    }
    self.update(orca_status: os)
  end

  protected

  # BEGIN ORCA SECTION
  def get_grading_script
    fail NotImplementedError, "Each grader should implement this"
  end

  def generate_files_hash(sub)
    fail NotImplementedError, "Each grader should implement this"
  end

  def dockerfile_sha_sum
    fail NotImplementedError, "Each grader should implement this"
  end

  def send_job_to_orca(submission, secret)
    orca_url = Grader.orca_config['site_url'][Rails.env]
    job_json = JSON.generate(generate_grading_job(submission, secret))
    put_job_json_with_retry!(URI.parse("#{orca_url}/api/v1/grading_queue"), job_json)
  end

  def generate_grading_job(sub, secret)
    grade = grade_for sub
    collation = if sub.team
                then { id: sub.team.id.to_s, type: "team" }
                else { id: sub.user.id.to_s, type: "user" } end
    {
      key: JSON.generate({ secret: secret }),
      files: generate_files_hash(sub),
      response_url: grade.orca_response_url,
      script: get_grading_script(sub),
      metadata_table: generate_metadata_table(sub),
      grader_image_sha: dockerfile_sha_sum,
      collation: collation,
      priority: delay_for_sub(sub).in_seconds
    }
  end

  def send_grading_request_to_orca(assignment, submission)
    Thread.new do
      config_details = "(assn #{assignment.id}, sub #{submission.id}, grader #{self.id})"
      
      grade = grade_for submission
      grade.submission_grader_dir.mkpath
      Audit.log("Attempting to send job #{config_details} to Orca.")
      begin
        FileUtils.rm grade.orca_result_path if grade.has_orca_output?
        secret, secret_file_path = generate_orca_secret!(grade.submission_grader_dir)
        Audit.log("Orca secret created for #{config_details}.")
        put_response = send_job_to_orca(submission, secret)
        if put_response['response_code'] == 200
          save_orca_job_status grade, put_response['status']
          Audit.log("Sent job #{config_details} to Orca")
        else
          FileUtils.rm(secret_file_path)
          error_str = "#{config_details} Response Code: #{put_response['response_code']}"
          if put_response['errors']
            error_str << "\nErrors:\n#{put_response['errors'].join("\n")}"
          end
          Audit.log(error_str)
          write_failed_job_result error_str, grade.orca_result_path
        end
      rescue IOError => e
        error_str = "Failed to create secret for job #{config_details}; encountered the following: #{e}\n#{e.backtrace.join('\n')}"
        Audit.log(error_str)
        write_failed_job_result(error_str, grade.orca_result_path)
      rescue StandardError => e
        FileUtils.rm(secret_file_path) if File.exist? secret_file_path
        error_str = "Unexpected error while attempting to create and send job #{config_details} to Orca; enountered the following: #{e}"
        Audit.log(error_str)
        write_failed_job_result(error_str, grade.orca_result_path)
      end
    end
  end
  
  def orca_image_build_config
    url_helpers = Rails.application.routes.url_helpers
    response_url = "#{Settings['site_url']}/#{url_helpers.orca_response_api_grader_path(self)}"
    dockerfile_contents = File.read(dockerfile_path)
    sha_sum = dockerfile_sha_sum
    {
      dockerfile_contents: dockerfile_contents,
      dockerfile_sha_sum: sha_sum,
      response_url: response_url
    }
  end

  # Generates a secret to be paired with an Orca grading job
  # and compared upon response. Returns the secret and the
  # file_path to which it was saved.
  def generate_orca_secret!(secret_save_dir)
    secret_length = 32
    secret = SecureRandom.hex(secret_length)
    file_path = secret_save_dir.join("orca.secret")
    File.open(file_path, "w") do |secret_file|
      secret_file.write(secret)
    end
    [secret, file_path]
  end

  def write_failed_job_result(error_str, result_path)
    result = generate_failed_job_result(error_str)
    File.open(result_path, 'w') do |f|
      f.write(result.to_json)
    end
  end

  def generate_failed_job_result(error_str)
    {
      type: "GradingJobResult",
      shell_responses: [],
      errors: [error_str]
    }
  end

  def put_job_json_with_retry!(orca_uri, job_json)
    # Exponential back off variables. Wait time in ms.
    max_requests = 5
    attempts = 0
    while true
      http_obj = Net::HTTP.new(orca_uri.host, orca_uri.port)
      http_obj.use_ssl = orca_uri.instance_of? URI::HTTPS
      response = http_obj.send_request(
        'PUT',
        orca_uri.path,
        job_json,
        {
          'Content-Type' => 'application/json',
          'x-api-key' => Settings['orca_api_key']
        }
      )
      break unless should_retry_web_request? response.code.to_i
      attempts += 1
      break if attempts == max_requests
      sleep(2**attempts + rand)
    end
    body = JSON.parse(response.body)
    unless response.code.to_i == 200
      return { 'response_code' => response.code.to_i, 'errors' => body['errors'] }.compact
    end
    { 'response_code' => response.code.to_i, **body }
  end

  def post_image_request_with_retry(orca_uri, image_build_req_body)
    max_requests = 5
    attempts = 0
    while true
      response = Net::HTTP.post(
        orca_uri,
        JSON.generate(image_build_req_body),
        {
          'Content-Type' => 'application/json',
          'x-api-key' => Settings['orca_api_key']
        }
      )
      break unless should_retry_web_request? response.code.to_i
      attempts += 1
      break if attempts == max_requests
      sleep(2**attempts + rand)
    end
    [JSON.parse(response.body), response.code.to_i]
  end

  def should_retry_web_request?(status_code)
    [503, 504].include? status_code
  end

  # END ORCA SECTION

  
  def delay_for_sub(sub)
    # Delay = 1 minute * # of subs (excluding given sub) in the last 15 minutes.
    delay_window = Grader.orca_config['queue']['delay_window_mins'].minutes
    delay_base = Grader.orca_config['queue']['delay_base_mins'].minutes
    recent_subs = assignment.submissions_for(sub.team || sub.user)
                    .where('created_at >= :start_time', { start_time: sub.created_at - delay_window })
                    .count - 1
    recent_subs * delay_base
  end

  def save_uploads
    self.upload&.save!
    self.extra_upload&.save!
  end

  def recompute_grades
    # nothing to do by default
  end

  def do_grading(assignment, submission)
    fail NotImplementedError, "Each grader should implement this"
  end

  def grade_for(sub, nosave = false)
    g = Grade.find_or_initialize_by(grader_id: self.id, submission_id: sub.id)
    if g.new_record?
      g.out_of = self.avail_score
      g.save unless nosave
    end
    g
  end

  def is_int(v)
    Integer(v) rescue false
  end
  def is_float(v)
    Float(v) rescue false
  end
  def add_error(msg)
    order = self.assignment.graders.sort_by(&:order).index(self)
    self.errors.add("##{order + 1}", msg)
  end
end

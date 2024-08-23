require 'webmock/minitest'
require 'test_helper'

class JunitGraderTest < ActiveSupport::TestCase
  include ActionDispatch::TestProcess

  def assignment_creation
    @fred = create(:user, name: 'Fred McTeacher', first_name: 'Fred', last_name: 'McTeacher', nickname: 'Fred')
    term = Term.create(semester: Term.semesters[:fall], year: Date.current.year, archived: false)
    late_per_day = LatePerDayConfig.create(days_per_assignment: 1, percent_off: 50,
                                           frequency: 1, max_penalty: 100)
    @course = Course.new(name: 'Computing 101', term: term, lateness_config: late_per_day)
    @sections = (1..3).map do |_|
      build(:section, course: @course, instructor: @fred)
    end
    @course.sections = @sections
    @course.save
    fred_reg = Registration.create(course: @course, user: @fred, role: Registration.roles[:professor],
                                   show_in_lists: false, new_sections: @sections)
    fred_reg.save_sections

    @student = create(:user)
    student_reg = Registration.create(course: @course, user: @student,
                                      role: Registration.roles[:student], show_in_lists: true,
                                      new_sections: [@sections.sample])
    student_reg.save_sections

    ts = Teamset.create(course: @course, name: 'Teamset 1')

    @asgn = Files.create(name: 'Assignment 2', blame: @fred, lateness_config: late_per_day,
                         course: @course, available: Time.current - 10.days, due_date: Time.current - 5.days,
                         points_available: 2.5, teamset: ts)

    junit_upload = build(:upload, user: @fred, assignment: @asgn)
    junit_upload.upload_data = FakeUpload.new(Rails.root.join('test/fixtures/files/junit-example.zip').to_s)
    @junit_grader = JunitGrader.new(assignment: @asgn, upload: junit_upload, avail_score: 50, order: 1)
    @junit_grader.test_class = 'ExampleTestClass'
    @junit_grader.errors_to_show = 3
    @junit_grader.test_timeout = 10

    def @junit_grader.autograde?; false end

    @asgn.graders << @junit_grader
    @asgn.save!
    sleep 0.1
  end

  setup do
  end

  def submission_grade_creation
    upload = fixture_file_upload('HelloWorld/HelloWorld.tgz', 'application/octet-stream')
    @sub = build(:submission, user: @student, assignment: @asgn, upload_file: upload)
    @sub.save_upload
    @sub.save!

    @grade = Grade.new(submission: @sub, grader: @junit_grader)
    @grade.save!

    @sub.reload
  end

  test 'receive successful image build response' do
    message = 'this grader already exists on the server; no build needed.'
    mock_build_response = { message: message }.to_json
    push_build_request_url = "#{Grader.orca_config['site_url']['test']}/api/v1/grader_images"
    stub_request(:post, push_build_request_url)
      .to_return(body: mock_build_response, status: 200, headers: { 'content-type' => 'application/json' })

    assignment_creation
    assert @junit_grader.orca_build_result['was_successful']
    assert_equal @junit_grader.orca_build_result['logs'].first, message
  end

  test 'receive bad request image build response' do
    errors = ['Validation errors', 'e1']
    mock_build_response = { errors: errors }.to_json
    push_build_request_url = "#{Grader.orca_config['site_url']['test']}/api/v1/grader_images"
    stub_request(:post, push_build_request_url)
      .to_return(body: mock_build_response, status: 400, headers: { 'content-type' => 'application/json' })

    assignment_creation
    assert_not @junit_grader.orca_build_result['was_successful']
    assert @junit_grader.orca_build_result['logs'].first.include?(errors.join("\n"))
  end

  test 'receive successful job push response' do
    mock_build_response = { message: 'this grader already exists on the server; no build needed.' }.to_json
    push_build_request_url = "#{Grader.orca_config['site_url']['test']}/api/v1/grader_images"
    stub_request(:post, push_build_request_url)
      .to_return(body: mock_build_response, status: 200, headers: { 'content-type' => 'application/json' })

    mock_job_response = { message: 'ok', status: { location: 'Queue', id: 52 } }.to_json
    push_job_request_url = "#{Grader.orca_config['site_url']['test']}/api/v1/grading_queue"
    stub_request(:put, push_job_request_url)
      .to_return(status: 200, body: mock_job_response, headers: { 'content-type' => 'application/json' })

    assignment_creation
    submission_grade_creation

    @junit_grader.grade(@asgn, @sub)
    sleep 0.1
    assert_not File.exist?(@grade.orca_result_path)
    assert File.exist?(@junit_grader.orca_job_status_path(@grade))
    assert_equal @junit_grader.orca_job_status_for(@grade)['location'], 'Queue'
  end

  test 'receive bad request job push response' do
    mock_build_response = { message: 'this grader already exists on the server; no build needed.' }.to_json
    push_build_request_url = "#{Grader.orca_config['site_url']['test']}/api/v1/grader_images"
    stub_request(:post, push_build_request_url)
      .to_return(body: mock_build_response, status: 200, headers: { 'content-type' => 'application/json' })

    errors = %w[e1 e2]
    mock_job_response = { errors: errors }.to_json
    push_job_request_url = "#{Grader.orca_config['site_url']['test']}/api/v1/grading_queue"
    stub_request(:put, push_job_request_url)
      .to_return(status: 400, body: mock_job_response, headers: { 'content-type' => 'application/json' })

    assignment_creation
    submission_grade_creation

    @junit_grader.grade(@asgn, @sub)
    sleep 0.1
    assert File.exist?(@grade.orca_result_path)
    assert @grade.orca_output['errors'].first.include? errors.join("\n")
    assert_not File.exist?(@junit_grader.orca_job_status_path(@grade))
  end
end

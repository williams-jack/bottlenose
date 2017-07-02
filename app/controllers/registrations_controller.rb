require 'csv'

class RegistrationsController < ApplicationController
  layout 'course'

  before_action :find_course
  before_action :find_registration, except: [:index, :new, :create, :bulk_enter, :bulk_update, :bulk_edit]
  before_action :require_current_user, except: [:public]
  before_action :require_registered_user, except: [:public, :index, :new, :create]
  before_action :require_admin_or_staff

  def index
    @students = @course.students
    @staff = @course.staff
    @requests = @course.reg_requests.joins(:user).order('role desc', 'name').includes(:user)
  end

  def new
    @registration = Registration.new
  end

  def create
    reg_params = registration_params

    uu = User.find_by(username: reg_params[:username])
    if uu
      @registration = Registration.find_by(course_id: @course, user_id: uu.id)
    end
    if @registration
      @registration.assign_attributes(reg_params)
    else
      # Create @registration object for errors.
      @registration = Registration.new(reg_params)
    end

    if @registration && @registration.save && @registration.save_sections
      redirect_to course_registrations_path(@course),
                  notice: 'Registration was successfully created.'
    else

      render action: :new
    end
  end

  def bulk_edit
    @course = Course.find(params[:course_id])
    if params[:role] == "student"
      @registrations = @course.registrations
                       .where(role: Registration::roles["student"])
    else
      @registrations = @course.registrations
                       .where.not(role: Registration::roles["student"])
    end
    @registrations = @registrations
                     .includes(:user)
                     .includes(:registration_sections)
                     .to_a.sort_by{|r| r.user.display_name}
  end

  def bulk_update
    respond_to do |f|
      f.json {
        @reg = Registration.find(params[:id])
        if @reg.nil? or @reg.course.id != @course.id
          render :json => {failure: "Unknown registration"}
        else
          changed = false
          @reg.dropped_date = nil if params[:reenroll]
          @reg.role = params[:role]
          section_param_names.each do |sectype|
            next unless params[sectype]
            type = sectype.to_s.gsub("_section", "")
            rs = RegistrationSection.where(registration: @reg).find{|rs| rs.section.type == type}
            if rs
              rs.section_id = params[sectype].to_i
              if rs.changed?
                changed = true
                rs.save
              end
            end
          end
          if @reg.changed? || changed
            @reg.save
            render :json => @reg
          else
            render :json => {"no-change": true}
          end
        end
      }
      f.html do
        redirect_back(fallback_location: course_registrations_path(@course), notice: "No such page")
      end
    end
  end

  def bulk_enter
    @course = Course.find(params[:course_id])
    num_added = 0
    failed = []

    CSV.parse(params[:usernames]) do |row|
      uu = User.find_by(username: row[0])
      if uu
        r = Registration.find_by(course_id: @course, user_id: uu.id)
      end
      if r
        r.assign_attributes(course_id: @course.id, new_sections: row[1..-1],
                            username: row[0], role: "student")
      else
        # Create @registration object for errors.
        r = Registration.new(course_id: @course.id, new_sections: row[1..-1],
                             username: row[0], role: "student")
      end

      if (r.save && r.save_sections)
        num_added += 1
      else
        failed << row[0]
      end
    end

    if failed.blank?
      redirect_to course_registrations_path(@course),
                  notice: "Added #{pluralize(num_added, 'student')}."
    else
      failed.each do |f| @course.errors.add(:base, f) end
      redirect_to course_registrations_path(@course),
                  notice: "Added #{num_added} students.",
                  alert: "Could not add #{pluralize(failed.count, 'student')}: #{failed.join(", ")}"
    end
  end

  def destroy
    @registration.destroy

    redirect_to course_registrations_path(@course)
  end

  private

  def find_registration
    @registration = Registration.find(params[:id])
    @course = @registration.course
    @user   = @registration.user
  end

  def registration_params
    ans = params.require(:registration)
          .permit(:course_id, :orig_sections, :new_sections, :role, :username, :show_in_lists, :tags)
    ans[:course_id] = params[:course_id]
    ans[:new_sections] = params[:new_sections].reject(&:blank?)
    ans
  end

  def section_param_names
    Section::types.map{|t, _| "#{t}_section"}
  end
end

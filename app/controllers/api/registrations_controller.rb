module Api
  class RegistrationsController < ApiController
    before_action :find_course
    before_action :require_registered_user
    before_action :require_admin_or_prof_ever

    def index
      registrations_by_section = @course.sections.map do |sec|
        [
          sec.id,
          {
            type: sec.type,
            meeting_time: sec.meeting_time,
            students: sec.students.map do |s|
              serialize_user(s)
            end
          }
        ]
      end.to_h
      render json: registrations_by_section
    end
  end
end
module Api
  class GradersController < ApiController
    skip_before_action :doorkeeper_authorize!
    before_action :find_grader

    def orca_response
      return head :missing if @grader.nil?
      return head :bad_request unless @grader.orca_status

      @grader.handle_image_build_attempt(
        params[:logs].map { |l| l.permit!.to_h },
        params[:was_successful]
      )
      head :ok
    end

    private

    def find_grader
      @grader = Grader.find_by_id params[:id]
    end
  end
end

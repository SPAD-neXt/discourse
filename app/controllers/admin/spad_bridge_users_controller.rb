# frozen_string_literal: true

class Admin::SpadBridgeUsersController < Admin::AdminController
  def index
    raise Discourse::InvalidAccess if !is_api?
    offset = params.fetch(:offset, "0")
    raise Discourse::InvalidParameters.new(:offset) if !offset.to_s.match?(/\A[0-9]{1,10}\z/)
    response.headers["Cache-Control"] = "no-store"
    render json:
             SpadBridgeUserInventory.page(
               admin_id: current_user.id,
               snapshot_id: params[:snapshot_id],
               offset: offset.to_i,
             )
  end
end

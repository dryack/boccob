class BotException < RuntimeError
  private
  def interpolate(id, msg)
    msg.sub!(/###/, id.nil? ? "" : " for '#{id}'")
  end
end

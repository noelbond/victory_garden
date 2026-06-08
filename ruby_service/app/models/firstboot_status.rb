class FirstbootStatus
  attr_reader :status, :log_path

  def self.current
    new(state_dir: state_dir)
  end

  def self.state_dir
    Pathname.new(ENV.fetch("VG_FIRSTBOOT_STATE_DIR", "/var/lib/victory-garden"))
  end

  def initialize(state_dir:)
    @state_dir = state_dir
    @complete_marker = @state_dir.join("firstboot-complete")
    @failed_marker = @state_dir.join("firstboot-failed")
    @log_path = @state_dir.join("firstboot.log")
    @status = detect_status
  end

  def managed?
    @complete_marker.exist? || @failed_marker.exist? || @log_path.exist?
  end

  def complete?
    status == "complete"
  end

  def failed?
    status == "failed"
  end

  def running?
    status == "running"
  end

  def available_log?
    @log_path.file?
  end

  def last_lines(limit = 12)
    return [] unless available_log?

    lines = @log_path.read.split("\n").map(&:strip).reject(&:blank?)
    lines.last(limit)
  rescue Errno::ENOENT
    []
  end

  def summary
    case status
    when "complete"
      "Image provisioning completed successfully."
    when "failed"
      "Image provisioning failed before the install reached a healthy running state."
    when "running"
      "Image provisioning is still running."
    else
      "No image provisioning status is available on this system."
    end
  end

  private

  def detect_status
    return "complete" if @complete_marker.exist?
    return "failed" if @failed_marker.exist?
    return "running" if @log_path.exist?

    "unmanaged"
  end
end

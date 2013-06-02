# Depending on puppet version, this feature may or may not include the libraries needed, but
# if some of them are present, the others should be too.
if Puppet.features.microsoft_windows?
  require 'win32/registry.rb' 
  require 'Win32API'  
end
require 'set'

Puppet::Type.type(:windows_env).provide(:windows_env) do
  desc "Manage Windows environment variables"

  confine :osfamily => :windows
  defaultfor :osfamily => :windows

  # http://msdn.microsoft.com/en-us/library/windows/desktop/ms681382%28v=vs.85%29.aspx
  self::ERROR_FILE_NOT_FOUND = 2

  self::REG_HIVE = Win32::Registry::HKEY_LOCAL_MACHINE
  self::REG_PATH = 'System\CurrentControlSet\Control\Session Manager\Environment'

  def exists?
    if @resource[:ensure] == :present && [nil, :nil].include?(@resource[:value])
      self.fail "'value' parameter must be provided when 'ensure => present'"
    end
    if @resource[:ensure] == :absent && [nil, :nil].include?(@resource[:value]) && 
      [:prepend, :append, :insert].include?(@resource[:mergemode])
      self.fail "'value' parameter must be provided when 'ensure => absent' and 'mergemode => #{@resource[:mergemode]}'"
    end

    @sep = @resource[:separator]

    if @resource[:value].class != Array
      @resource[:value] = [@resource[:value]]
    end

    begin
      self.class::REG_HIVE.open(self.class::REG_PATH, Win32::Registry::KEY_READ) { |key| @value = key[@resource[:variable]] } 
    rescue Win32::Registry::Error => error
      if error.code == self.class::ERROR_FILE_NOT_FOUND
        debug "Environment variable #{@resource[:variable]} not found"
        return false
      end
      reg_fail('reading', error)
    end

    @value = @value.split(@sep)

    # Assume that if the user says 'ensure => absent', they want the value to
    # be removed regardless of its position, i.e. use the 'insert' behavior
    # when removing in 'prepend' and 'append' modes. Otherwise, if the value
    # were in the variable but not at the beginning (prepend) or end (append),
    # it would not be removed. 
    if @resource[:ensure] == :absent && [:append, :prepend].include?(@resource[:mergemode])
      @resource[:mergemode] = :insert
    end

    case @resource[:mergemode]
    when :clobber
      # When 'ensure == absent' in clobber mode, we delete the variable itself, regardless of its content, so
      # don't bother checking the content in this case. 
      @resource[:ensure] == :present ? @value == @resource[:value] : true
    when :insert
      Set.new(@resource[:value].map { |x| x.downcase }).subset?(Set.new(@value.map { |x| x.downcase }))
    when :append
      @value.map { |x| x.downcase }[(-1 * @resource[:value].count)..-1] == @resource[:value].map { |x| x.downcase }
    when :prepend
      @value.map { |x| x.downcase }[0..(@resource[:value].count - 1)] == @resource[:value].map { |x| x.downcase }
    end
  end

  def create
    debug "Creating or inserting value into environment variable '#{@resource[:variable]}'"

    # If the registry item doesn't exist yet, creation is always treated like
    # clobber mode, i.e. create the new reg item and populate it with
    # @resource[:value]
    if not @value
      @resource[:mergemode] = :clobber
    end

    case @resource[:mergemode]
    when :clobber
      begin
        self.class::REG_HIVE.create(self.class::REG_PATH, Win32::Registry::KEY_WRITE) do |key| 
          key[@resource[:variable]] = @resource[:value].join(@sep) 
        end
      rescue Win32::Registry::Error => error
        reg_fail('creating', error)
      end
    # the position at which the new value will be inserted when using insert is
    # arbitrary, so may as well group it with append.
    when :insert, :append
      # delete if already in the string and move to end. 'remove_value' will have no effect in 'insert' mode; we would not have
      # reached this point if there were something to remove. 
      remove_value
      @value = @value.concat(@resource[:value]).join(@sep)
      key_write { |key| key[@resource[:variable]] = @value }
    when :prepend
      # delete if already in the string and move to front
      remove_value
      @value = @resource[:value].concat(@value).join(@sep)
      key_write { |key| key[@resource[:variable]] = @value }
    end
    broadcast_changes
  end

  def destroy
    debug "Removing value from environment variable '#{@resource[:variable]}', or removing variable itself"
    case @resource[:mergemode]
    when :clobber
      key_write { |key| key.delete_value(@resource[:variable]) }
    when :insert, :append, :prepend
      remove_value
      key_write { |key| key[@resource[:variable]] = @value.join(@sep) }
    end
    broadcast_changes
  end

  private

  def reg_fail(action, error)
    self.fail "#{action} '#{self.class::REG_HIVE.name}:\\#{self.class::REG_PATH}\\#{@resource[:variable]}' returned error #{error.code}: #{error.message}"
  end

  def remove_value
    @value = @value.delete_if { |x| @resource[:value].find { |y| y.casecmp(x) == 0 } }
  end

  def key_write(&block)
    self.class::REG_HIVE.open(self.class::REG_PATH, Win32::Registry::KEY_WRITE, &block)
  rescue Win32::Registry::Error => error
    reg_fail('writing', error)
  end

  # Make new variable visible without logging off and on again.
  #
  # see: http://stackoverflow.com/questions/190168/persisting-an-environment-variable-through-ruby/190437#190437
  # and: http://msdn.microsoft.com/en-us/library/windows/desktop/ms644952%28v=vs.85%29.aspx
  # and: http://msdn.microsoft.com/en-us/library/windows/desktop/ms725497%28v=vs.85%29.aspx
  # and for good measure: http://ruby-doc.org/stdlib-1.9.2/libdoc/dl/rdoc/Win32API.html
  self::SendMessageTimeout = Win32API.new('user32', 'SendMessageTimeout', 'LLLPLLP', 'L')
  def broadcast_changes
    debug "Broadcasting changes to environment"
    # About the args: 0xFFFF        = HWND_BROADCAST (send to all windows)
    #                 0x001A        = WM_SETTINGCHANGE (the message to send, informs windows a system change has occurred)
    #                 0             = NULL (this should always be NULL with WM_SETTINGCHANGE)
    #                 'Environment' = (string indicating what changed. This refers to the 'Environment' registry key)
    #                 2             = SMTO_ABORTIFHUNG (return without waiting timeout period if receiver appears to hang)
    #                 bcast timeout = (How long to wait for a window to respond to the event. Each window gets this amount of time)
    #                 0             = (Return value. We're ignoring it)
    self.class::SendMessageTimeout.call(0xFFFF, 0x001A, 0, 'Environment', 2, @resource[:broadcast_timeout], 0)
  end    
end
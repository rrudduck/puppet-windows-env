Puppet::Type.newtype(:windows_env) do
  desc "Manages Windows environment variables"

  ensurable

  # title will look like "#{variable}=#{value}" (The '=' is not permitted in 
  # environment variable names). If no '=' is present, user is giving only
  # the variable name (for deletion purposes, say, or to provide an array),
  # so value will be set to nil (and possibly overridden later). 
  def self.title_patterns
    [[/^(.*?)=(.*)$/, [[:variable, proc{|x| x}], [:value, proc{|x| x   }]]],
     [/^([^=]+)$/   , [[:variable, proc{|x| x}]]]]
  end

  newparam(:variable) do
    desc "The environment variable name"
    isnamevar
  end

  newparam(:value) do
    desc "The environment variable value"
    isnamevar
  end

  newparam(:mergemode) do
    desc "How to set the value of the environment variable. E.g. replace existing value, append to existing value..."
    newvalues(:clobber, :insert, :append, :prepend)
    defaultto(:insert)
  end

  newparam(:separator) do
    desc "How to separate environment variables with multiple values (e.g. PATH)"
    defaultto(';')
  end

  newparam(:broadcast_timeout) do
    desc "Set the timeout (in ms) for environment refreshes. This is per top level window, so delay may be longer than provided value."
    validate do |val|
      begin
        Integer(val)
      rescue ArgumentError 
        raise ArgumentError, "broadcast_timeout must be a valid integer"
      end
    end
    munge { |val| Integer(val) }
    defaultto(5000)
  end
end
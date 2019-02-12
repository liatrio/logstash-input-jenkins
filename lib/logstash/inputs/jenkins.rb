# encoding: utf-8
require "socket" # for Socket.gethostname

# Generate a repeating message.
#
# This plugin is intented only as an example.

class LogStash::Inputs::Jenkins < LogStash::Inputs::Http

  config_name "jenkins"

  # If undefined, Logstash will complain, even if codec is unused.
  default :codec, "json"

  config :host, :validate => :string, :default => "jenkins.liatr.io"

  #config :port, :validate => :number, :default => 8080

  public



end # class LogStash::Inputs::Jenkins

# encoding: utf-8
require "socket" # for Socket.gethostname
require "logstash/inputs/http"

# Generate a repeating message.
#
# This plugin is intented only as an example.

class LogStash::Inputs::Jenkins < LogStash::Inputs::Http

  config_name "jenkins"

  # If undefined, Logstash will complain, even if codec is unused.
  default :codec, "json"

  config :host, :validate => :string, :default => "jenkins.liatr.io"

  config :port, :validate => :number, :default => 80

  # Username for basic authorization
  config :user, :validate => :string, :required => false

  # Password for basic authorization
  config :password, :validate => :password, :required => false

  public



end # class LogStash::Inputs::Jenkins

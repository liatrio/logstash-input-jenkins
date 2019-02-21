# encoding: utf-8
require "socket" # for Socket.gethostname
require "logstash/inputs/http"
require "ostruct"
require "json"
require "elasticsearch"
require "pp"
require "date"



# This plugin utilizes Jenkins' Logstash plugin linked here:
#   https://wiki.jenkins.io/display/JENKINS/Logstash+Plugin
# The plugin will interpret the Jenkins logs sent to logstash and interpret them according to
# our elasticsearch structure. We currently determine whether or not a project built from a repository
# is a 'build' or 'deploy' job. The plugin then links the a job that has been ran with a corresponding
# bitbucket repo as well as a jira issue. We also calculate the lead-time in this project and report this
# information to elasticsearch.

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

  config :elastic_port, :validate => :number, :default => 9200

  config :elastic_host, :validate => :string, :default => '192.168.0.27'

  config :elastic_scheme, :validate => :string, :default => 'http'

  public

  def decode_body(headers, remote_address, body, default_codec, additional_codecs)
    content_type = headers.fetch("content_type", "")
    codec = additional_codecs.fetch(HttpUtil.getMimeType(content_type), default_codec)

    #decode the body to get the relevant info we want from JSON from jenkins
    temp = JSON.parse(body)

    # Iterate through the jenkins' logs to access all of the fields we need
    if temp['data']['buildVariables']['TYPE'] == "deploy"

      artifact_id = temp['data']['buildVariables']['id']
      artifact_group = temp['data']['buildVariables']['group']
      artifact_version = temp['data']['buildVariables']['version']

      client = Elasticsearch::Client.new(:hosts => "#{@elastic_scheme}://#{@elastic_host}:#{@elastic_port}")

      #client.search utilizes the elasticsearch ruby library to send a query to elasticsearch from the logstash plugin
      repo_response = client.search index: 'lead_time', body:
      {
          "query": {
              "bool": {
                  "must": [
                      {
                          "nested": {
                              "path": "builds",
                              "query": {
                                  "term": {
                                      "builds.artifact.id": {
                                          "value": artifact_id
                                      }
                                  }
                              }
                          }
                      },
                      {
                          "nested": {
                              "path": "builds",
                              "query": {
                                  "term": {
                                      "builds.artifact.group": {
                                          "value": artifact_group
                                      }
                                  }
                              }
                          }
                      },
                      {
                          "nested": {
                              "path": "builds",
                              "query": {
                                  "term": {
                                      "builds.artifact.version": {
                                          "value": artifact_version
                                      }
                                  }
                              }
                          }
                      }
                  ]
              }
          }
      }

      repo_response["hits"]["hits"].each do |hit|
        lead_time_document = hit["_source"]

        deploys = []
        #Determines if the lead_time doc build field exists
        if lead_time_document["deploys"].nil?
          puts "running????"
          lead_time_document["deploys"] = deploys
          end

        start = lead_time_document["started_at"]
        create = lead_time_document["created_at"]
        finish = temp['@buildTimestamp']

        start_date = DateTime.parse(start).to_time.to_i
        finish_date = DateTime.parse(finish).to_time.to_i
        create_date = DateTime.parse(create).to_time.to_i
        total_time = finish_date - start_date
        progress_time = finish_date - create_date

        lead_time_document["deploys"].push(
           {
             environment: temp['data']['buildVariables']['ENV'],
             result: temp['data']['result'],
             completed_at: temp['@buildTimestamp'],
             total_time: total_time,
             progress_time: progress_time,
           }
        )
        if temp['data']['buildVariables']['ENV'] == "prod"
          lead_time_document["prod"] =
          {
              total_time: total_time,
              progress_time: progress_time
          }
        elsif temp['data']['buildVariables']['ENV'] == "qa"
          lead_time_document["qa"] =
          {
              total_time: total_time,
              progress_time: progress_time
          }
        elsif temp['data']['buildVariables']['ENV'] == "dev"
          lead_time_document["dev"] =
          {
              total_time: total_time,
              progress_time: progress_time
          }
        else
          puts "other env"
        end

        if temp['data']['result'] == 'SUCCESS'
        lead = LogStash::Event.new(lead_time_document)
        lead.set('[@metadata][index]', 'lead_time')
        lead.set('[@metadata][id]', hit['_id'])
        @queue << lead
        end
      end

    elsif temp['data']['buildVariables']['TYPE'] == nil
      if temp['data']['buildVariables']['POM_GROUPID'] != nil &&
          temp['data']['buildVariables']['POM_ARTIFACTID'] != nil &&
          temp['data']['buildVariables']['POM_VERSION'] != nil

        commit_id = temp['data']['buildVariables']['GIT_COMMIT']
        client = Elasticsearch::Client.new(:hosts => "#{@elastic_scheme}://#{@elastic_host}:#{@elastic_port}")

        repo_response = client.search index: 'lead_time', body:
        {
          "query": {
              "nested": {
                  "path": "commits",
                  "query": {
                      "term": {
                          "commits.id": {
                              "value": commit_id
                          }
                      }
                  }
              }
          }
        }

        builds = []
        repo_response["hits"]["hits"].each do |hit|
          lead_time_document = hit["_source"]


          #Determines if the lead_time doc build field exists
          if lead_time_document["builds"].nil?
            lead_time_document["builds"] = builds
          end

          lead_time_document["builds"].push({artifact:
          {
            id: temp['data']['buildVariables']['POM_ARTIFACTID'],
            group: temp['data']['buildVariables']['POM_GROUPID'],
            name: temp['data']['buildVariables']['JOB_NAME'],
            version: temp['data']['buildVariables']['POM_VERSION'],
            packaging: temp['data']['buildVariables']['POM_PACKAGING']
          },
            result: temp['data']['result'],
            built_at: temp['@buildTimestamp']
            }
          )

          if temp['data']['result'] == 'SUCCESS'
            lead = LogStash::Event.new(lead_time_document)
            lead.set('[@metadata][index]', 'lead_time')
            lead.set('[@metadata][id]', hit['_id'])
            @queue << lead
          end
        end
      else
        puts "build that isn't maven build or deploy"
      end
    else
      puts "JON IS NUB"
    end

    gg = LogStash::Event.new(temp)
    gg.set('[@metadata][index]', 'build')
    push_decoded_event(headers, remote_address, gg)

    #codec.decode(body) { |event| push_decoded_event(headers, remote_address, event) }
    codec.flush { |event| push_decoded_event(headers, remote_address, event) }
    true
  rescue => e
    @logger.error(
        "unable to process event.",
        :message => e.message,
        :class => e.class.name,
        :backtrace => e.backtrace
    )
    false
  end

end # class LogStash::Inputs::Jenkins

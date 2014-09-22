#!/usr/bin/env ruby
#

require 'rubygems' if RUBY_VERSION < '1.9.0'
require 'sensu-handler'

class BaseHandler < Sensu::Handler
  def event_is_ok?
    @event['check']['status'] == 0
  end

  def event_is_critical?
    @event['check']['status'] == 2
  end

  def event_is_warning?
    @event['check']['status'] == 1
  end

  def human_check_status
    case @event['check']['status']
    when 0
      'OK'
    when 1
      'WARNING'
    when 2
      'CRITICAL'
    else
      'UNKNOWN'
    end
  end

  def should_page?
    @event['check']['page'] || false
  end

  def runbook
    @event['check']['runbook'] || false
  end

  def team_name
    if @event['check']['team'] then
      @event['check']['team']
    else
      bail "check did not provide a team name"
    end
  end

  def team_data(lookup_key = nil)
    return unless team_name
    data = settings[self.class.name.downcase]['teams'][team_name] || {}
    if lookup_key
      data = data[lookup_key]
    end
    yield(data) if data && block_given?
    data
  end

  def tip
    @event['check']['tip']
  end

  def description(maxlen=0)
    description = @event['check']['notification']
    description ||= [@event['client']['name'], @event['check']['name'], @event['check']['output']].join(' : ')
    if event_is_critical? or event_is_warning?
      toadd = ""
      if tip
        toadd = "#{toadd} - #{tip}"
      end
      if runbook
        toadd = "#{toadd} (#{runbook})"
      end
      if maxlen > 0 && (toadd.length + description.length) > maxlen
        description_size = maxlen - toadd.length - 1
        if description_size > 0
          description = description[0..description_size]
        end
      end
      description = "#{description}#{toadd}"
    end
    description.gsub("\n", ' ')
  end

  def full_description
    body = <<-BODY
#{@event['check']['output']}

Dashboard Link: #{dashboard_link}
Runbook: #{runbook}
Tip: #{tip}

Command:  #{@event['check']['command']}
Status:  #{@event['check']['status']}

Timestamp: #{Time.at(@event['check']['issued'])}
Occurrences:  #{@event['occurrences']}

Team: #{team_name}
Host: #{@event['client']['name']}
Address:  #{@event['client']['address']}
Check Name:  #{@event['check']['name']}
Habitat: #{habitat}

BODY
    body
  end

  def full_description_hash
    {
      'Output' => @event['check']['output'],
      'Dashboard Link' => dashboard_link,
      'Host' => @event['client']['name'],
      'Timestamp' => Time.at(@event['check']['issued']),
      'Address' => @event['client']['address'],
      'Check Name' => @event['check']['name'],
      'Command' => @event['check']['command'],
      'Status' => @event['check']['status'],
      'Occurrences' => @event['occurrences'],
      'Team' => team_name,
      'Habitat' => habitat,
      'Runbook' => runbook,
      'Tip' => tip
    }
  end

  def dashboard_link
    "https://systems-#{habitat}.yelpcorp.com/sensu/"
  end

  def habitat
    file_name='/nail/etc/habitat'
    begin
      File.read(file_name).strip
    rescue
      "UNKNOWN"
    end
  end

  # == Custom Yelp Filter Logic
  # We have multiple output handlers and routing logic, and we to ensure
  # that both active and passive checks and take advantage of it
  # Addionally we want to simplify the timing logic as much as possible.
  #
  # To that end we take the following event data to determine if we should
  # create an alert or not:
  #
  def filter_repeated
    if @event['check']['name'] == 'keepalive'
      # Keepalives are a special case because they don't emit an interval.
      # They emit a heartbeat every 20 seconds per
      # http://sensuapp.org/docs/0.12/keepalives
      interval = 20
    else
      interval      = @event['check']['interval']      || 0
    end
    alert_after   = @event['check']['alert_after']  || 0
    realert_every = @event['check']['realert_every']   || 1
    failing_for   = @event['occurrences'].to_i * @event['check']['interval'].to_i

    # Don't bother acting if we haven't hit the 
    # alert_after threshold
    if failing_for < alert_after
      bail "Only failing for #{failing_for}, less than #{alert_after}. Not performing any action yet."
    # If we have an interval, and this is a creation event, that means we are an active check
    # Lets also filter based on the realert_every setting
    elsif interval > 0 and @event['action'] == 'create' 
      initial_failing_occurrences = alert_after.fdiv(interval).to_i
      number_of_failed_attempts = @event['occurrences'] - initial_failing_occurrences
      # Special case of exponential backoff
      if realert_every.to_i == -1
        # If our number of failed attempts is an exponent of 2^
        if (Math::log(number_of_failed_attempts) / Math::log(2)) % 1 == 0
          # Then This is our MOMENT!
          realert_every = number_of_failed_attempts
        else
          # Fake realert to be higher so we dont alert
          realert_every = number_of_failed_attempts + 1
        end
      end
      if number_of_failed_attempts == 1
        # Always alert the first time that we pass the alert_after threshold
        return nil
      end
      # Now bail if we are not in the realert_every cycle
      unless number_of_failed_attempts == 0 || number_of_failed_attempts % realert_every == 0
        bail 'only handling every ' + realert_every.to_s + ' occurrences, and we are at ' + number_of_failed_attempts.to_s
# DEBUG
#      else
#        puts 'Continuing because we realert every ' + realert_every.to_s + ' and we are at ' + number_of_failed_attempts.to_s
      end
    end
  end

end

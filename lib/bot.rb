# encoding: utf-8

require "cinch"
require "redis"
require "elasticsearch"
require "json"
require 'marky_markov'

# Monkeypatch to always reply w/ prefix
module Cinch
  class Message
    alias_method :real_reply, :reply
    def reply(text, prefix=nil)
      prefix ||= true
      real_reply(text, prefix)
    end
  end
end


class Seen < Struct.new(:who, :time)
  def to_s
    "#{who} was last seen on #{time.asctime}"
  end
end

class Fifteen < Struct.new(:time, :who, :message)
  def to_s
    "[#{time.strftime("%m/%d %I:%M%p")}] <#{who}> #{message}"
  end
end

# returns true or false based on chance in 100
def random_chance(chance)
  prng = Random.new
  if (prng.rand(99)+1) <= chance
    return true
  else
    return false
  end
end

#
# Define main invocation path outside of make_bot/Cinch::Bot so it can be
# tested in isolation.
#

module Responder
  attr_accessor :tracker

  def initialize(*args)
    super
  end

  def _respond(msg, cmd=nil)
    # Deal with empty cmd (implies privmsg)
    cmd = msg.message if cmd.nil?
    # Tokenize
    subcmd, *args = cmd.split
    # Collect parameters & put into final dict (but not if command is marked
    # as "I don't do kwargs".)
    unless Dispatcher.kwargless.include?(subcmd)
      kvs, args = args.partition {|x| x.include?('=')}
      kvs = Hash[kvs.map {|x| x.split('=')}]
      args << kvs unless kvs.empty?
    end
    # Dispatch
    subcmd = subcmd.to_sym
    # Ensure we only send to defined commands (methods on Dispatcher
    # itself) and not arbitrary Ruby methods
    if Dispatcher.commands.include? subcmd
      # Give dispatcher access to msg so it can reply arbitrarily, etc
      Dispatcher.new(msg, @tracker).send(subcmd, *args)
    else
      msg.reply "ಠ_ಠ wat?"
    end
  end

  def respond(msg, cmd=nil)
    _respond(msg, cmd)
  rescue BotException => e
    log e.inspect
    msg.reply "(╯°□°)╯︵ ┻━┻  No can do. #{e}"
  rescue ArgumentError => e
    puts e.message
    msg.reply sprintf("%s%s\n", e.message, cmd.nil? ? "" : " for #{cmd}")
  rescue => e
    # Barf into logs
    log e.inspect
    log e.backtrace
    # But tell the client instead of actually reraising
    msg.reply "(ノಠ益ಠ)ノ彡 ┻━┻  What is this, I don't even. #{e.inspect}"
  end
end

# Pull that into a subclass of Cinch::Bot for use in make_bot
class Bot < Cinch::Bot
  include Responder
end


#
# Bot gets defined here, mostly responsible for invocation duties, help etc
#

def make_bot
  Bot.new do
    # Get irc config from global config
    irc_config = CONFIG['irc']

    configure do |c|
      # Connection
      c.server = irc_config['server']
      c.port = irc_config['port']
      c.ssl.use = irc_config['use_ssl']
      c.ping_interval = irc_config['ping_interval']
      c.timeouts.read = irc_config['timeout_sec']

      # Who to be, where
      c.nick = irc_config['nick']
      c.realname = "Boccob, the #greytalk bot!"
      c.channels = irc_config['channels'].map {|x| "##{x}"}
      c.user = irc_config['user']

      # Owners => password
      $ownerlist = CONFIG['ownerlist']

      # deal with markov stuffs
      $markov = MarkyMarkov::Dictionary.new('dictionary') # Saves/opens dictionary.mmd

      # While debugging
      c.reconnect = irc_config['reconnect']
    end
    
    # spinup to work with redis
    $redis = Redis.new CONFIG['redis']
    $redis_msg_queue = Redis.new CONFIG['redis2']
    $redis_search_history = Redis.new CONFIG['redis4']
    $users = {}
    #$users[msg.user.nick] = Seen.new(msg.user.nick, Time.new)
    #$redis.set "users_seen", $users.to_json
    $users = JSON.parse($redis.get("users_seen"))
    $fifteen = {}

    # maximum number of users ever seen concurrently in channel
    $max_users_conc = $redis.get("users_conc").to_i

    # spinup for elasticsearch
    $es = Elasticsearch::Client.new CONFIG['elasticsearch']

    # Respond to all PRIVMSG (but not NOTICE) as if they were commands
    on(:private) do |msg|
      bot.respond(msg) unless msg.command == 'NOTICE' || msg.message == 'shutup'
    end

    nick = irc_config['nick']
    # Respond to public channel messages if they are obviously addressing us,
    # e.g. !alfred, alfred:, alfred, etc
    bang = "^!#{nick}"
    reference = "^#{nick}[:,]"
    regular = "^#{nick}"
    invoke = "(#{bang}|#{regular})"
    on(:channel, /#{invoke} (.*)/) do |msg, _, cmd|
      bot.respond(msg, cmd)
    end

    # Treat empty invocations as "help"
    on(:channel, /#{invoke}$/) do |msg|
      bot.respond(msg, "help")
    end

    # Respond to bang commands if they correspond to one of our commands.
    # TODO: deal with conflicts w/ other bots? heh...
    branches = Dispatcher.commands.map(&:to_s).join '|'
    rgx = /^!(#{branches})( .+)?$/
    on(:channel, rgx) do |msg, subcmd, rest|
      # LOL serialization. Just reattach subcommand + anything after it.
      bot.respond(msg, subcmd + rest.to_s)
    end

    # Detect links and let the bot handle them if it wants
    on(:channel, /http/i) do |msg|
      URI.extract(msg.message, %w(http https)) do |uri|
        begin
          Dispatcher.new(msg).handle_uri(uri)
        rescue => e
          log e.inspect
          log e.backtrace
        end
      end
    end

    # Support !seen command
    on(:channel) do |msg|
      unless msg.user.nick =~ /^.+_guest.*$/
        $users[msg.user.nick] = Seen.new(msg.user.nick, Time.new)
        $redis.set "users_seen", $users.to_json
      end
    end
    
    # populate the 15 minute log, and trim as needed
    on(:channel) do |msg|
      $fifteen = Fifteen.new(msg.time, msg.user.nick, msg.message)
      $redis_msg_queue.rpush "fifteen_msg", $fifteen.to_json
      #if $redis_msg_queue.llen("fifteen_msg").to_i > 3300
      $redis_msg_queue.ltrim("fifteen_msg", -3300, -1)  # store max of 3300 messages
      #end
      $fifteen = {}
    end

    # markov sillies
    on(:channel, /^#{reference}/) do |msg|
      Dispatcher.new(msg).saysomething(2)
    end

    # Respond to invites and join that channel for remainder of session.
    on(:invite) do |msg|
      msg.channel.join
    end

    # funny stuff
    on(:channel, /mimic/i) do |msg|
      if random_chance(10) == true
        msg.channel.send "http://i.imgur.com/epffrPq.jpg"
      end
    end
      
    on(:channel, /beholder/i) do |msg|
      if random_chance(10) == true
        funnies = ["http://i.imgur.com/zyjrtzp.jpg",
                   "http://i.imgur.com/bLJQE4G.jpg",
                   "http://i.imgur.com/1YjTOjy.jpg"]
        msg.channel.send "#{funnies.sample}"
      end
    end

    # Alert folks that the channel is still alive, and allow them to silence
    # this message in the future
    on(:join) do |msg|
      $shutup_list = $redis.lrange("shutup_list", "0", "#{$redis.llen("shutup_list")}")
      unless $shutup_list.include?("#{msg.user}")
      # TODO: iterate over the configs so code changes will be unnecessary for
      # messages
      sleep 10
      msg.user.send "#{CONFIG['automessages']['auto']}"
      msg.user.send "#{CONFIG['automessages']['wiki']}"
      msg.user.send "#{CONFIG['automessages']['shutup']}"
      end
    end
    
    # !seen users as they join the channel - except for the guests
    on(:join) do |msg|
      unless msg.user.nick =~ /^.+_guest.*$/
        $users[msg.user.nick] = Seen.new(msg.user.nick, Time.new)
        $redis.set "users_seen", $users.to_json
      end
    end

    # track record number of people in chat
    on(:channel) do |msg|
      user_count = msg.channel.users.count - 1
      if user_count > $max_users_conc
        $max_users_conc = user_count
        $redis.set("users_conc", "#{$max_users_conc}")
        msg.channel.send "We've hit a new high number of concurrent users, with #{$max_users_conc}!"
      end
    end


    # identify self to ChanServ and obtain +o
    on(:join) do |msg|
      if msg.user.nick == "#{nick}"
        sleep 10
        User('NickServ').send "#{CONFIG['services']['identify']}"
        sleep 2
        User('ChanServ').send "#{CONFIG['services']['autocmd']}"
      end
    end

    # Kickban people as needed
    on(:private, /^kickban/) do |msg|
      if $ownerlist.include?("#{msg.user.nick}")
        User('ChanServ').send "KICKBAN #greytalk #{msg.params[1].to_str.sub!(/kickban /,'')}"
      else
        msg.user.send "Sorry, this command is for owners only."
      end
    end
    
    # Provide method for users to shut up :join PMs from boccob
    on(:private, /^shutup$/) do |msg|
      $shutup_list = $redis.lrange("shutup_list", "0", "#{$redis.llen("shutup_list")}")
      unless $shutup_list.include?("#{msg.user}")
        $redis.lpush "shutup_list", "#{msg.user}"
      end
    end
  end
end

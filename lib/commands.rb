# encoding: utf-8
require 'cinch'
require 'date'
require 'httparty'
require 'json'
require 'open3'
require 'nokogiri'
require 'cgi'
require 'util'
require 'open-uri'
require 'roll'

#
# Actual commands the bot invokes
#

class Dispatcher
  class << self
    # Classmethod returning command list (just: our public methods.)
    def commands
      new.public_methods(false)
    end

    # Classmethod returning commands that don't want/need key=value kwarg
    # autosplitting.
    def kwargless
      %w(topic)
    end
  end

  # Store message object for commands to access if necessary
  def initialize(msg=nil, tracker=nil)
    @msg = msg
    @tracker = tracker
  end

  # Show available commands to the user.
  def help
    # Always /msg the user, even if they asked for help publicly.
    # This prevents verbose help messages from flooding channels.
    @msg.reply "/msg'd" if @msg.channel?
    commands = self.class.commands.sort.join(', ')
    @msg.user.send "Available commands: #{commands}"
  end
 
  def topic(*args)
    if $ownerlist.include?("#{@msg.user.nick}")
      topic_help = "!topic <subcommand> [<args>]
                  get: displays the topic.\n
                  set <content>: overrides the topic, setting it to content. E.g. !topic set This is the new topic.\n
                  add <content>: appends content to the topic.\n
                  insert <content>: prepends content to the topic.\n
                  remove <position>: removes chunk at given position from topic.\n
                  replace <position> <content>: replaces the chunk at position with content.\n
                  reorder <positions>: reorders the topic based on given positions indexes. E.g. if the topic is currently foo | bar | biz, saying !topic reorder 1 0 2 would change the topic to bar foo biz."
      # send help if no args/subcommands
      return @msg.user.send("#{topic_help}") if args.empty?
      # Setup
      delimit_char = '|'
      delimiter = " #{delimit_char} "
      command = args.shift
      topic = @msg.channel.topic.split(delimiter)
      # Delimiter protection
      if args.any? {|x| x.include?(delimit_char)}
        return @msg.reply("Don't manually insert delimiters ('|'), please!")
      end
      # Short-circuit on 'get'
      msg = "The topic is #{topic.join(delimiter).inspect}"
      return @msg.reply(msg) if command == 'get'
      # Setters set topic
      topic = case command
      when 'set'
        return @msg.reply("I need something to set!") if args.empty?
        args.join(' ')
      when 'add', 'insert'
        return @msg.reply("I need something to #{command}!") if args.empty?
        value = args.join ' '
        method = command == 'add' ? :push : :unshift
        topic.send(method, value)
      when 'remove', 'replace'
        # Input tests
        unless numeric?(args.first)
          msg = "#{command}'s first argument needs to be a numeric index!"
          return @msg.reply(msg)
        end
        index = args.first.to_i
        max = topic.size - 1
        err = "Index '#{index}' is out of bounds! The topic only goes to #{max}."
        return @msg.reply(err) if index > max
        # Action
        case command
        when 'remove'
          topic.delete_at(index)
        when 'delete'
          topic.delete_at(index)
        when 'replace'
          topic[args.shift.to_i] = args.join(' ')
        end
        # Neither of the above methods return the mutated array :(
        topic
      when 'reorder'
        # Indexes should be numeric
        unless args.all? {|x| numeric?(x)}
          return @msg.reply("'reorder' only takes numeric index arguments!")
        end
        indexes = args.map(&:to_i)
        # And not out of bounds
        max = topic.size - 1
        indexes.each do |i|
          e = "Index '#{i}' is out of bounds! The topic only goes to #{max}."
          return @msg.reply e if i > max
        end
        # And we should not be missing any (don't really care about extras tho)
        missing = 1.upto(max).reject {|x| indexes.include?(x)}
        unless missing.empty?
          return @msg.reply("You forgot some indexes: #{missing.join(', ')}.")
        end
        # Update
        indexes.map {|x| topic.fetch(x)}
      else
        cmds = %w(get set add insert remove replace reorder).join('|')
        return @msg.reply("Invalid command! Needs to be one of: #{cmds}.")
      end
      @msg.channel.topic = topic.is_a?(Array) ? topic.join(delimiter) : topic
    else # checking for ownership
      if args.empty?
        delimit_char = '|'
        delimiter = " #{delimit_char} "
        topic = @msg.channel.topic.split(delimiter)
        msg = "The topic is #{topic.join(delimiter).inspect}"
        return @msg.reply(msg)
      else
        @msg.user.send "Sorry, this command is for owners only."
      end
    end
  end
  
  def bsearch(*search_term)
    # keep regular users from using - comment out once ready for production
    #unless $ownerlist.include?("#{@msg.user.nick}")
    #  return @msg.reply "Search is disabled for non-owners at this time."
    #end
    search_term = search_term.join(" ")
    run_search("private", search_term)
  end
  
  def recent(number=10)
    @msg.reply "/msg sent"
    result = $redis_search_history.lrange("recent_searches", "-#{number.to_i}","100")
    result = result.uniq
    result.each {|entry|
      x = JSON.parse(entry)
      @msg.user.send "#{x[0]} - #{x[1]}"}
  end
  
  # subject for discussion
  def subject
    chosen_line = nil
    encycfile = "#{CONFIG['subjectfileloc']}"
    File.foreach(encycfile).each_with_index do |line, number|
      chosen_line = [line, number] if rand < 1.0/(number+1) and line =~ /\[.*\]$/
    end
    @msg.reply chosen_line[0]
  end
  
  # saysomething
  def saysomething(sentences=1)
    @msg.reply $markov.generate_n_sentences(sentences.to_i)
  end
  
  # dice
  def dice(roll_command, *rest)
    help_text = 
    "!dice [num]d<num> [num times] || !roll [num]%<num> [num times] || !roll [num]d<num>[+|-|*|/][d][num] [numtimes]\n \n
     The dice command suports order of precendence, including parentheses.  The following
     examples are all valid rolls (see the min/max possible numbers within the square brackets:\n \n
     d%                [1, 100]\n
     2d%               [2, 200]\n
     d3*2              [2, 6]\n
     2d3+8             [10, 14]\n
     (2d(3+8))         [2, 22]\n
     d3+d3             [2, 6]\n
     d3d3              [1, 9]\n
     5d6d7             [5, 210]\n
     10d10             [10, 100]\n
     10d10 2           [10 10, 100 100]\n
     3d6 6             [3 3 3 3 3 3, 18 18 18 18 18 18]\n
     (5d5-4)d(15/d4)+3 [4, 339]"
    roll_command = roll_command.split(' ')
    roll_command << rest
    roll_command.flatten!
    unless roll_command[0].downcase == 'help'
      d = Dice.new(roll_command[0])
      @msg.reply("#{Array.new((roll_command[1] || 1).to_i) { d.roll }.join(' ')}")
     else 
      @msg.reply "/msg'd"
      @msg.user.send(help_text)
    end
  end

  # seen
  def seen(nick)
    if nick == 'boccob'
      @msg.reply "I have always been!"
    elsif nick == @msg.user.nick
      @msg.reply "You're right here!"
    elsif $users.key?(nick)
      $users = JSON.parse($redis.get( "users_seen"))
      @msg.reply $users[nick].to_s
    else
      @msg.reply "#{nick} hasn't been seen"
    end
  end

  def replay(max_lines=30)
    if max_lines.to_i > 3300 || max_lines.to_i < 2
      @msg.reply "!replay supports from 2 to 3300 lines, with a default of 30"
    else 
      fifteen = $redis_msg_queue.lrange("fifteen_msg", "-#{max_lines.to_i}","3300")
      @msg.reply "/msg sent"
      fifteen.each {|msg_num| @msg.user.send msg_num}
    end
  end

  def story(user=@msg.user.nick)
    @msg.channel.send "Come sit by the fire children, #{user} is about to tell a story!"
  end

# DEBUG/informational:  shutup_list
  def check_sul
    if $ownerlist.include?("#{@msg.user.nick}")
      @msg.user.send "#{$shutup_list}"
    else
      @msg.user.send "Sorry, this command is for owners only."
    end
  end
  
  # DEBUG/informational:  $users (for !seen)
  def check_usn
    if $ownerlist.include?("#{@msg.user.nick}")
      @msg.user.send "#{JSON.parse($redis.get("users_seen"))}"
    else
      @msg.user.send "Sorry, this command is for owners only."
    end
  end

  # DEBUG/informational:  $max_users_conc
  def check_muc
    if $ownerlist.include?("#{@msg.user.nick}")
      @msg.user.send "#{$redis.get("users_conc")}"
    else
      @msg.user.send "Sorry, this command is for owners only."
    end
  end

  def seen_all
    if $ownerlist.include?("#{@msg.user.nick}")
      $users.each_key {|key| @msg.user.send $users[key].to_s }
    else
      @msg.user.send "Sorry, this command is for owners only."
    end
  end
  
  # DO NOT ADD NEW COMMANDS AFTER THIS 'private' MARKER!

  private


#  from standards discussion at work - fix my garbage
#
#  def coordinating_method
#    do_thing
#    do_another_thing
#    do_yet_another
#    other_shit
#  end
#  
#  def other_shit
#    if something
#       this_thing
#       if something_else
#          fuck
#       end
#    end
#  end

  def run_search(type="private", search_term)
    # query type for later consideration:
    # http://nocf-www.elastic.co/guide/en/elasticsearch/reference/current/query-dsl-simple-query-string-query.html
    # result = @es.search index: 'codex', sort: '_id', _source_include: ['title','page'], body: { query: { simple_query_string: { query: "Boccob"} } }
    # query type for the time being:
    # http://nocf-www.elastic.co/guide/en/elasticsearch/reference/current/query-dsl-match-query-phrase.html
    
    # prior version
    #result = $es.search index: 'codex', sort: '_id', _source_include: ['title','page'], body: { query: { match_phrase: { text: { 'query': "#{search_term}"} } } }
    result = $es.search index: 'codex', _source_include: ['title','page'], size: 1500, body: { query: { match_phrase: { text: { 'query': "#{search_term}"} } } }
    time = result['took']
    total_hits = result['hits']['total']
    @msg.user.send "Searched for \"#{search_term}\" in #{time}ms - #{total_hits} #{plural_if_needed(total_hits, 'result')} found"
    output = Hash.new{ |h, k| h[k] = [] }
    result['hits']['hits'].each { |x|
      output[x['_source']['title']].push(x['_source']['page'])
    }
    if output == {}
      @msg.user.send "No results returned."
      return
    end
    # manage search history - don't add empty results
    update_search_history(search_term) unless output == {}
    output.keys.sort.each { |k| output[k] = output.delete k }
    max_key_length = output.keys.max {|a,b| a.length <=> b.length }.length
    output.each_pair { |k,v|
      if type == "public"
        @msg.reply "#{k}, #{plural_if_needed(v.count, 'page')} #{v.sort.join(', ')}" unless k == "{}"
      else
        @msg.user.send "#{k.rjust(max_key_length)} - #{plural_if_needed(v.count, 'page').rjust(5)} #{v.sort.join(', ')}" unless k == "{}"
      end
    }
    @msg.user.send "End of results."
    @msg.reply "End results for search \"#{search_term}\"" unless type == "private"
  end
  
  def update_search_history(search_term)
    $redis_search_history.rpush "recent_searches", ["#{@msg.user.nick}","#{search_term}"].to_json
    $redis_search_history.ltrim "recent_searches", -100, -1 #storing 100 searches
  end

  def plural_if_needed(num, singular, plural=nil)
    if num == 1
      "#{singular}"
    elsif plural
      "#{plural}"
    else
      "#{singular}s"
    end
  end

# someday i might actually bother finishing this?
#
#  def establish_owner?(msg)
#    msg.user.send "Password?"
#    p $ownerlist["#{@msg.user}"]
#    p @msg.message
#    @msg = nil
#    if @msg.message == $ownerlist["#{@msg.user}"][0]
#      return true
#    else
#      return false
#    end
#  end
  
  def channel_reply(txt, user=nil)
    user ||= @msg.user.nick
    @msg.channel.send "#{user}: #{txt}"
  end

  # i did a thing - i should use it... eventually?
  def nick_here?(nick)
    @msg.channel.users.map {|user, modes| user}.include? nick
  end

end

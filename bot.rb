# encoding: utf-8

require 'yaml'

#
# Config
#

CONFIG = YAML.load_file(ARGV[0])


#
# Import components
#

$LOAD_PATH.unshift File.join(Dir.getwd, 'lib') # meh
require 'util'
require 'bot'
require 'commands'
require 'exceptions'


#
# Execution
#

make_bot.start if CONFIG['run_bot']

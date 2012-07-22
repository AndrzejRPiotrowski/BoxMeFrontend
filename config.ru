require "rubygems"
require "bundler"


Bundler.require

require "./app"
use Rack::CommonLogger
run Sinatra::Application

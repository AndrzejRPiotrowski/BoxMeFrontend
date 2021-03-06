require "sinatra"
require "sinatra/reloader"
require 'dropbox_sdk'
require 'koala'
require 'json'
require 'net/http'
require "uri"
require 'open-uri'
require 'socket'

$ACCEPTING_CONNECTIONS = false
DROPBOX_APP_KEY = "u4d52lnoqpoqztk"
DROPBOX_APP_SECRET = "58xjxsb08ybg584"
DROPBOX_ACCESS_TYPE = :dropbox    #The two valid values here are :app_folder and :dropbox
                          #The default is :app_folder, but your application might be
                          #set to have full :dropbox access.  Check your app at
                          #https://www.dropbox.com/developers/apps

enable :sessions
enable :logging, :dump_errors, :raise_errors, :show_exceptions

# Scope defines what permissions that we are asking the user to grant.
# In this example, we are asking for the ability to publish stories
# about using the app, access to what the user likes, and to be able
# to use their pictures.  You should rewrite this scope with whatever
# permissions your app needs.
# See https://developers.facebook.com/docs/reference/api/permissions/
# for a full list of permissions
FACEBOOK_SCOPE = ''

unless ENV["FACEBOOK_APP_ID"] && ENV["FACEBOOK_SECRET"] && ENV["DROPBOX_CALLBACK_DOMAIN"]
  abort("missing env vars: please set FACEBOOK_APP_ID and FACEBOOK_SECRET with your app credentials")
end

before do
  # HTTPS redirect
  if settings.environment == :production && request.scheme != 'https'
    redirect "https://#{request.env['HTTP_HOST']}"
  end
end

helpers do
  def host
    request.env['HTTP_HOST']
  end

  def scheme
    request.scheme
  end

  def url_no_scheme(path = '')
    "//#{host}#{path}"
  end

  def url(path = '')
    "#{scheme}://#{host}#{path}"
  end

  def authenticator
    @authenticator ||= Koala::Facebook::OAuth.new(ENV["FACEBOOK_APP_ID"], ENV["FACEBOOK_SECRET"], url("/auth/facebook/callback"))
  end

end

# the facebook session expired! reset ours and restart the process
error(Koala::Facebook::APIError) do
  session[:access_token] = nil
  session[:fbid] = nil
  redirect "/auth/facebook"
end

get "/" do
  # Get base API Connection
  @graph  = Koala::Facebook::API.new(session[:access_token])
  # Get public details of current application
  @app  =  @graph.get_object(ENV["FACEBOOK_APP_ID"])
  if session[:access_token]
    @dropbox_enabled = (session[:dropbox_session]) ? true : false
    @user    = @graph.get_object("me")
    #@friends = @graph.get_connections('me', 'friends')
    @friends = @graph.fql_query("SELECT uid, name, is_app_user, pic_square FROM user WHERE uid=1342512190 or uid=611336274 or uid=688985918 or uid=1048504295")
    #@photos  = @graph.get_connections('me', 'photos')
    #@likes   = @graph.get_connections('me', 'likes').first(4)
    # for other data you can always run fql
    @friends_using_app = @graph.fql_query("SELECT uid, name, is_app_user, pic_square FROM user WHERE uid in (SELECT uid2 FROM friend WHERE uid1 = me()) AND is_app_user = 1")
    # get root directory listing from back-backend
    session[:fbid]=@user["id"]
    if $ACCEPTING_CONNECTIONS
      port = 9125
      host = "23.21.149.90"
      socket = TCPSocket.new(host,port)
      all_data = []
      socket.print "{\"requestType\" : \"getFilesUnderPath\", \"requestParameters\" : [\"" + @user["id"] + "\", " + "\"/\"" + "]} \n\n"
      while partial_data = socket.read(1012)
        puts partial_data
        all_data << partial_data
      end
      socket.close
      @responsedir = JSON.parse(all_data.join)
    end
  end
  erb :index
end


# used by Canvas apps - redirect the POST to be a regular GET
post "/" do
  redirect "/"
end

# used to close the browser window opened to post to wall/send to friends
get "/close" do
  "<body onload='window.close();'/>"
end

get "/sign_out" do
  session[:access_token] = nil
  redirect '/'
end

get "/auth/facebook" do
  session[:access_token] = nil
  redirect authenticator.url_for_oauth_code(:permissions => FACEBOOK_SCOPE)
end

get '/auth/facebook/callback' do
	session[:access_token] = authenticator.get_access_token(params[:code])
	redirect '/'
end

get '/auth/dropbox' do 
  if not params[:oauth_token] 
    dropbox_session = DropboxSession.new(DROPBOX_APP_KEY, DROPBOX_APP_SECRET)
    session[:dropbox_session] = dropbox_session.serialize
    session[:request_token] = dropbox_session.get_request_token
    redirect dropbox_session.get_authorize_url(ENV["DROPBOX_CALLBACK_DOMAIN"])
  else
    puts"the user has returned from Dropbox"
    dropbox_session = DropboxSession.deserialize(session[:dropbox_session])
    @dropbox_access = dropbox_session.get_access_token()
    @dropbox_key = @dropbox_access.key
    @dropbox_secret = @dropbox_access.secret
    client = DropboxClient.new(dropbox_session, DROPBOX_ACCESS_TYPE) #raise an exception if session not authorized
    session[:dbuid] = client.account_info["uid"] # look up account information
    if $ACCEPTING_CONNECTIONS
      port = 9125
      host = "23.21.149.90"
      socket = TCPSocket.new(host,port)
      all_data = []
      socket.print "{\"requestType\" : \"registerDropboxAccount\", \"requestParameters\" : [\"" + session[:fbid].to_s + "\", \"" + session[:dbuid].to_s + "\", \"" + @dropbox_key.to_s + "\", \"" + @dropbox_secret.to_s + "\"] } \n\n"                                                                                                                                                      + "]} \n \n"
      while partial_data = socket.read(1012)
        puts partial_data
        all_data << partial_data
      end
      socket.close
    end

    session[:dropbox_session] = dropbox_session.serialize # re-serialize the authenticated session
    redirect '/'
  end
end

post '/browse' do 
  dir = params[:dir]
  if not session[:cur_dir]
    session[:cur_dir] = "/"
  end   
  @dropbox_enabled = (session[:dropbox_session]) ? true : false
  session[:cur_dir] = dir
  puts "Current Directory: #{dir}"
  if session[:cur_dir] == "/"
    if @dropbox_enabled    
      @dir = Hash[:dirs => ["dropbox"],
                  :files => []]
    else
      @dir = Hash[:dirs => [],
                  :files => []]
    end
  else
    if session[:cur_dir] == "/dropbox"
      @dir = Hash[:dirs => ["code", "website", "school_stuff"],
                  :files => ["this_file_is_in_my_dropbox.txt"]]
    elsif session[:cur_dir] == "/dropbox/code"
      @dir = Hash[:dirs => ["ruby", "python", "java"],
                  :files => ["this_file_is_in_my_dropbox.txt"]]
    elsif session[:cur_dir] == "/dropbox/code/ruby"
      @dir = Hash[:dirs => ["sinatra"],
                  :files => ["test.rb"]] 
    elsif session[:cur_dir] == "/dropbox/code/ruby/sinatra"
      @dir = Hash[:dirs => ["boxme"],
                  :files => [""]]
    elsif session[:cur_dir] == "/dropbox/code/ruby/sinatra/boxme"
      @dir = Hash[:dirs => ["public", "views"],
                  :files => ["app.rb","config.ru","Gemfile","Procfile","Readme"]]
    elsif session[:cur_dir] == "/dropbox/code/ruby/sinatra/boxme/views"
      @dir = Hash[:dirs => [],
                  :files => ["index.erb"]]
    elsif session[:cur_dir] == "/dropbox/code/ruby/sinatra/boxme/public"
      @dir = Hash[:dirs => ["images","javascripts","stylesheets"],
                  :files => ["channel.html"]]
    elsif session[:cur_dir] == "/dropbox/code/ruby/sinatra/boxme/public/images"
      @dir = Hash[:dirs => [],
                  :files => ["amazon-s3.png","dropbox-icon.png","google-drive-icon.png","skydrive-icon.png"]]  
    elsif session[:cur_dir] == "/dropbox/code/ruby/sinatra/boxme/public/javascripts"
      @dir = Hash[:dirs => [],
                  :files => ["jquery-1.7.1.min.js","jquery-ui-1.8.21.custom.min.js"]]
    elsif session[:cur_dir] == "/dropbox/code/ruby/sinatra/boxme/public/stylesheets"
      @dir = Hash[:dirs => [],
                  :files => ["base.css","mobile.css","reset.css","screen.css"]]    
    
    else
      @dir = Hash[:dirs => [],
                  :files => []]
    end
  end
  
  @output = "<div id='file-browser'>"
  if @dropbox_enabled 
    if session[:cur_dir] != '/'
      parent = session[:cur_dir].split("/")[0...-1].join("/")
      parent = (parent == "" ? "/" : parent)
      @output += "<h4><a href='#' class='directory' id='#{parent}'>Back</a>"
    else
      @output += "<h4>Back"
    end
    @output += "</h4><h5>Current Directory: #{session[:cur_dir]} </h5>"
    @output += "<ul class='friends' id='files-ul'>"
    unless @dir[:dirs].empty?
      @dir[:dirs].each do |dir|
        @output += "<li><a class='directory' id='#{session[:cur_dir]}"
        @output += "/" if session[:cur_dir] != '/'
        @output += dir + "' href='#'>#{dir}</a></li>"
      end
    end
    unless @dir[:files].empty?
      @dir[:files].each do |file|
        @output += "<li id='#{session[:cur_dir]}"
        @output += "/" if session[:cur_dir] != '/'
        @output += session[:cur_dir]+file+"'>#{file}</li>"
      end
    end
    @output += "</ul>"
  else
    @output += "<p>You don't have any files!</p>"
  end
  @output += "</div>"
  # parse Backend.getFilesUnderPath(session[:user_id], session[:cur_dir]).to_json into html and return
  return @output 
end
  
get '/back' do
  parent = session[:cur_dir].split("/")[0...-1].join("/")
  parent = (parent == "" ? "/" : parent)
  session[:cur_dir] = parent
  redirect '/'
end

post '/share' do
  friend_id = params["friend_id"]
  filename = params["file_name"]
  fbid = session[:fbid]
  if $ACCEPTING_CONNECTIONS
    port = 9125
    host = "23.21.149.90"
    socket = TCPSocket.new(host,port)
    all_data = []
    socket.print "{\"requestType\" : \"putFiles\", \"requestParameters\" : [\"" + session[:fbid].to_s + "\", [\"dropbox/" + session[:dbuid].to_s + "/" + filename + "\"], [\"" + friend_id  + "\"]]}\n\n"                                                                                                                                                      + "]} \n \n"
    while partial_data = socket.read(1012)
      puts partial_data
      all_data << partial_data
    end
    socket.close
  end
  
  
end





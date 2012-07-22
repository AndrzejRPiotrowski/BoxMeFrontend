require "sinatra"
require "sinatra/reloader"
require 'dropbox_sdk'
require 'koala'
require 'json'
require 'net/http'
require "uri"
require 'open-uri'
require 'socket'


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
  redirect "/auth/facebook"
end

get "/" do
  # Get base API Connection
  @graph  = Koala::Facebook::API.new(session[:access_token])

  # Get public details of current application
  @app  =  @graph.get_object(ENV["FACEBOOK_APP_ID"])
  
  if session[:access_token]
    @user    = @graph.get_object("me")
    @friends = @graph.get_connections('me', 'friends')
    @photos  = @graph.get_connections('me', 'photos')
    @likes   = @graph.get_connections('me', 'likes').first(4)
    # for other data you can always run fql
    @friends_using_app = @graph.fql_query("SELECT uid, name, is_app_user, pic_square FROM user WHERE uid in (SELECT uid2 FROM friend WHERE uid1 = me()) AND is_app_user = 1")
    # get root directory listing from back-backend
    
    if not session[:cur_dir]
      session[:cur_dir] = '\\'
    end   
    @cur_dir = session[:cur_dir]

=begin
    Socket.tcp("23.21.149.90", 9125) {|sock|
      sock.print "{\"requestType\" : \"getFileList\", \"requestParameters\" : [\"" + @user["id"] + "\", " + "\"/\"" + "]} \n \n"
      sock.close_write
      response = sock.read
    }
    @response = response
=end

    #url = URI.parse("http://23.21.149.90:9125/getDirectory?uid=#{uid}&dir=#{session[:dir]}")
    #response = Net::HTTP::Post.new(url.path) 
    #@dir = JSON.parse(response)
    
    if @cur_dir == '\\'      
      @dir = Hash["dirs" => ["google_drive", "dropbox"],
                  "files" => ["random_text.txt"]]
    elsif @cur_dir == "\\google_drive"
      @dir = Hash["dirs" => ["docs", "music", "movies"],
                  "files" => ["this_file_is_in_my_google_drive.txt"]]
    elsif @cur_dir == "\\dropbox"
      @dir = Hash["dirs" => ["code", "website", "school_stuff"],
                  "files" => ["this_file_is_in_my_dropbox.txt"]]
    else
      @dir = Hash["dirs" => [],
                  "files" => ["this_file_is_an error_file.txt"]]
    end
    @dirs = @dir["dirs"]
    @files = @dir["files"]
              
    if session[:dropbox_session]
      puts "Dropbox access is enabled!"
      dropbox_session = DropboxSession.deserialize(session[:dropbox_session])
      if dropbox_session.authorized?
        @dropbox_access = dropbox_session.get_access_token
      end
    end 

     
  end
  erb :index
end

get '/upload' do
   redirect '/' unless session[:dropbox_session]
   @dropbox_session = DropboxSession.deserialize(session[:dropbox_session])
   redirect '/' unless @dropbox_session.authorized?
   client = DropboxClient.new(@dropbox_session, DROPBOX_ACCESS_TYPE) #raise an exception if session not authorized
   puts "linked account:", client.account_info().inspect # look up account information
   file = open('test-file.txt')
   response = client.put_file('/test-file.txt', file)
   puts "uploaded:", response.inspect
   redirect "/"
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
    redirect dropbox_session.get_authorize_url("http://localhost:5000")
  else
    puts"the user has returned from Dropbox"
    dropbox_session = DropboxSession.deserialize(session[:dropbox_session])
    #dropbox_session.authorize(params)
    dropbox_session.get_access_token  #we've been authorized, so now request an access_token
    session[:dropbox_session] = dropbox_session.serialize # re-serialize the authenticated session
=begin
    Socket.tcp("23.21.149.90", 9125) {|sock|   fbid, dbid, accestoken, secretkey
      sock.print "{\"requestType\" : \"registerDropboxAccount\", \"requestParameters\" : [\"" + @user["id"] + "\", " + "\"/\"" + "]} \n \n"
      sock.close_write
      response = sock.read
    }
    @response = response
=end
    redirect '/'
  end
end

get '/browse/:directory' do 
  if :directory
    if session[:cur_dir] == "\\"
      session[:cur_dir] = session[:cur_dir]+params[:directory]
    else
     session[:cur_dir] = session[:cur_dir]+"\\"+params[:directory]
    end 
  end
  redirect '/'
end
  
get '/back' do
  parent = session[:cur_dir].split("\\")[0...-1].join("\\")
  parent = (parent == "" ? "\\" : parent)
  session[:cur_dir] = parent
  redirect '/'
end


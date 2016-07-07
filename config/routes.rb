Rails.application.routes.draw do

  controller "logjam/logjam" do
    get "/:year/:month/:day/live_stream", :year => /\d\d\d\d/, :month => /\d\d/, :day => /\d\d/, :action => 'live_stream', :format => false

    %w(
       allocated_objects_distribution
       allocated_size_distribution
       apdex_overview
       auto_complete_for_applications_page
       auto_complete_for_controller_action_page
       call_graph
       call_relationships
       callers
       enlarged_plot
       error_overview
       errors
       exceptions
       history
       js_exception_types
       js_exceptions
       leaders
       request_overview
       request_time_distribution
       response_code_overview
       response_codes
       show
       totals_overview
       user_agents
    ).each do |action|
      get "/:year/:month/:day/#{action}(/:id)", :year => /\d\d\d\d/, :month => /\d\d/, :day => /\d\d/, :action => action
    end

    get "/database_information" => :database_information

    get "/:year/:month/:day(/index(/:id))", :year => /\d\d\d\d/, :month => /\d\d/, :day => /\d\d/, :action => "index"

    get "/" => :index, :page => "::"
  end

  controller "logjam/admin" do
    get "/admin/storage" => :index, :as => "admin_storage"
    get "/admin/streams" => :streams
  end
end

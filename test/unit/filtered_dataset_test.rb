require_relative "../test_helper"

class FilteredDatasetTest < ActiveSupport::TestCase
  include Logjam::LogjamHelper

  test "clean_url_params removes default parameters" do
    params = ActionController::Parameters.new("grouping" => 'page', "start_minute" => "0")
    params.permit!
    new_params = clean_params(params)
    assert_equal Hash.new, new_params
  end

  test "clean_url_params keeps non-default parameters" do
    params = ActionController::Parameters.new("grouping" => 'requests', "start_minute" => "1")
    params.permit!
    new_params = clean_params(params)
    assert_equal({"grouping" => 'requests', "start_minute" => "1"}, new_params)
  end

  test "clean_url_params manages komplex shit" do
    params = {"app"=>"logjam", "env"=>"development", "grouping"=>"page", "controller"=>"logjam/logjam", "action"=>"index", "year"=>"2016", "month"=>"07", "day"=>"06", "section"=>"backend", "start_minute"=>"0", "end_minute"=>"1440", "resource"=>"total_time", "grouping_function"=>"sum", "interval"=>"5", "auto_refresh"=>"0", "time_range"=>"date", :default_app=>"logjam", :default_env=>"logjam"}
    new_params = clean_params(params)
    expected_params = {"app"=>"logjam", "env"=>"development", "controller"=>"logjam/logjam", "action"=>"index", "year"=>"2016", "month"=>"07", "day"=>"06"}
    assert_equal expected_params, new_params
  end
end

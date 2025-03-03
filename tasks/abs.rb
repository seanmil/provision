#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'net/http'
require 'yaml'
require 'puppet_litmus'
require 'etc'
require 'date'
require_relative '../lib/task_helper'

# Provision and teardown vms through ABS.
class ABSProvision
  include PuppetLitmus::InventoryManipulation

  # Enforces a k8s.infracore.puppet.net domain, but allows selection of prod,
  # stage, etc hostname from the environment variable +ABS_SUBDOMAIN+ so that
  # CI can test vms from staging.
  #
  # Defaults to abs-prod.k8s.infracore.puppet.net.
  def abs_host
    subdomain = ENV['ABS_SUBDOMAIN'] || 'abs-prod'
    "#{subdomain}.k8s.infracore.puppet.net"
  end

  def provision(platform, inventory_location, vars)
    uri = URI.parse("https://#{abs_host}/api/v2/request")
    jenkins_build_url = if ENV['CI'] == 'true' && ENV['TRAVIS'] == 'true'
                          ENV['TRAVIS_JOB_WEB_URL']
                        elsif ENV['CI'] == 'True' && ENV['APPVEYOR'] == 'True'
                          "https://ci.appveyor.com/project/#{ENV['APPVEYOR_REPO_NAME']}/build/job/#{ENV['APPVEYOR_JOB_ID']}"
                        elsif ENV['GITHUB_ACTIONS'] == 'true'
                          "https://github.com/#{ENV['GITHUB_REPOSITORY']}/actions/runs/#{ENV['GITHUB_RUN_ID']}"
                        else
                          'https://litmus_manual'
                        end
    poll_duration = ENV['POLL_ABS_TIMEOUT_SECONDS'] || 600

    # Job ID must be unique
    job_id = "iac-task-pid-#{Process.pid}-#{DateTime.now.strftime('%Q')}"

    headers = { 'X-AUTH-TOKEN' => token_from_fogfile('abs'), 'Content-Type' => 'application/json' }
    priority = ENV['CI'] ? 1 : 2
    payload = if platform.instance_of?(String)
                { 'resources' => { platform => 1 },
                  'priority' => priority,
                  'job' => { 'id' => job_id,
                             'tags' => { 'user' => Etc.getlogin, 'jenkins_build_url' => jenkins_build_url } } }
              else
                { 'resources' => platform,
                  'priority' => priority,
                  'job' => { 'id' => job_id,
                             'tags' => { 'user' => Etc.getlogin, 'jenkins_build_url' => jenkins_build_url } } }
              end
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    request = Net::HTTP::Post.new(uri.request_uri, headers)
    request.body = payload.to_json

    # Make an initial request - we should receive a 202 response to indicate the request is being processed
    reply = http.request(request)
    # Use this 'puts' only for debugging purposes
    # Do not use this in production mode because puppet_litmus will parse the STDOUT to extract the results
    # puts "#{Time.now.strftime('%Y/%m/%d %H:%M:%S')}: Received: #{reply.code} #{reply.message} from ABS"
    raise "Error: #{reply}: #{reply.message}" unless reply.is_a?(Net::HTTPAccepted) # should be a 202

    # We want to then poll the API until we get a 200 response, indicating the VMs have been provisioned
    timeout = Time.now.to_i + poll_duration.to_i # Let's poll the API for a max of poll_duration seconds
    sleep_time = 1

    # Progressively increase the sleep time by 1 second. When we hit 10 seconds, start querying every 30 seconds until we
    # exceed the time out. This is an attempt to strike a balance between quick provisioning and not saturating the ABS
    # API and network if it's taking longer to provision than usual
    while Time.now.to_i < timeout
      sleep (sleep_time <= 10) ? sleep_time : 30
      reply = http.request(request)
      # Use this 'puts' only for debugging purposes
      # Do not use this in production mode because puppet_litmus will parse the STDOUT to extract the results
      # puts "#{Time.now.strftime('%Y/%m/%d %H:%M:%S')}: Received #{reply.code} #{reply.message} from ABS"
      break if reply.code == '200' # Our host(s) are provisioned
      raise 'ABS API Error: Received a HTTP 404 response' if reply.code == '404' # Our host(s) will never be provisioned

      sleep_time += 1
    end

    raise "Timeout: unable to get a 200 response in #{poll_duration} seconds" if reply.code != '200'

    inventory_full_path = File.join(inventory_location, '/spec/fixtures/litmus_inventory.yaml')
    inventory_hash = get_inventory_hash(inventory_full_path)
    data = JSON.parse(reply.body)
    data.each do |host|
      if platform_uses_ssh(host['type'])
        node = { 'uri' => host['hostname'],
                 'config' => { 'transport' => 'ssh', 'ssh' => { 'user' => ENV['ABS_USER'], 'host-key-check' => false, 'connect-timeout' => 120 } },
                 'facts' => { 'provisioner' => 'abs', 'platform' => host['type'], 'job_id' => job_id } }
        if !ENV['ABS_SSH_PRIVATE_KEY'].nil? && !ENV['ABS_SSH_PRIVATE_KEY'].empty?
          node['config']['ssh']['private-key'] = ENV['ABS_SSH_PRIVATE_KEY']
        else
          node['config']['ssh']['password'] = ENV['ABS_PASSWORD']
        end
        group_name = 'ssh_nodes'
      else
        node = { 'uri' => host['hostname'],
                 'config' => { 'transport' => 'winrm', 'winrm' => { 'user' => ENV['ABS_WIN_USER'], 'password' => ENV['ABS_PASSWORD'], 'ssl' => false, 'connect-timeout' => 120 } },
                 'facts' => { 'provisioner' => 'abs', 'platform' => host['type'], 'job_id' => job_id } }
        group_name = 'winrm_nodes'
      end
      unless vars.nil?
        var_hash = YAML.safe_load(vars)
        node['vars'] = var_hash
      end
      add_node_to_group(inventory_hash, node, group_name)
    end

    File.open(inventory_full_path, 'w') { |f| f.write inventory_hash.to_yaml }
    { status: 'ok', nodes: data.length }
  end

  def tear_down(node_name, inventory_location)
    inventory_full_path = File.join(inventory_location, '/spec/fixtures/litmus_inventory.yaml')
    if File.file?(inventory_full_path)
      inventory_hash = inventory_hash_from_inventory_file(inventory_full_path)
      facts = facts_from_node(inventory_hash, node_name)
      platform = facts['platform']
      job_id = facts['job_id']
    end

    targets_to_remove = []
    inventory_hash['groups'].each do |group|
      group['targets'].each do |node|
        targets_to_remove.push(node['uri']) if node['facts']['job_id'] == job_id
      end
    end
    uri = URI.parse("https://#{abs_host}/api/v2/return")
    headers = { 'X-AUTH-TOKEN' => token_from_fogfile('abs'), 'Content-Type' => 'application/json' }
    payload = { 'job_id' => job_id,
                'hosts' => [{ 'hostname' => node_name, 'type' => platform, 'engine' => 'vmpooler' }] }
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    request = Net::HTTP::Post.new(uri.request_uri, headers)
    request.body = payload.to_json

    reply = http.request(request)
    raise "Error: #{reply}: #{reply.message}" unless reply.code == '200'

    targets_to_remove.each do |target|
      remove_node(inventory_hash, target)
    end
    File.open(inventory_full_path, 'w') { |f| f.write inventory_hash.to_yaml }
    { status: 'ok', removed: targets_to_remove }
  end

  def task(action:, platform: nil, node_name: nil, inventory: nil, vars: nil, **_kwargs)
    inventory_location = sanitise_inventory_location(inventory)
    result = provision(platform, inventory_location, vars) if action == 'provision'
    result = tear_down(node_name, inventory_location) if action == 'tear_down'
    result
  end

  def self.run
    params = JSON.parse($stdin.read)
    params.transform_keys!(&:to_sym)
    action, node_name, platform = params.values_at(:action, :node_name, :platform)

    raise 'specify a node_name when tearing down' if action == 'tear_down' && node_name.nil?
    raise 'specify a platform when provisioning' if action == 'provision' && platform.nil?

    unless node_name.nil? ^ platform.nil?
      case action
      when 'tear_down'
        raise 'specify only a node_name, not platform, when tearing down'
      when 'provision'
        raise 'specify only a platform, not node_name, when provisioning'
      else
        raise 'specify only one of: node_name, platform'
      end
    end

    begin
      runner = new
      result = runner.task(**params)
      puts result.to_json
      exit 0
    rescue StandardError => e
      puts({ _error: { kind: 'provision/abs_failure', msg: e.message } }.to_json)
      exit 1
    end
  end
end

ABSProvision.run if __FILE__ == $PROGRAM_NAME

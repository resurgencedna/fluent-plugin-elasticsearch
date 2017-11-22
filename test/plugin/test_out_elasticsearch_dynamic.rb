require 'helper'
require 'date'
require 'flexmock/test_unit'

class ElasticsearchOutputDynamic < Test::Unit::TestCase
  include FlexMock::TestCase

  attr_accessor :index_cmds, :index_command_counts

  def setup
    Fluent::Test.setup
    require 'fluent/plugin/out_elasticsearch_dynamic'
    @driver = nil
  end

  def driver(tag='test', conf='')
    @driver ||= Fluent::Test::BufferedOutputTestDriver.new(Fluent::ElasticsearchOutputDynamic, tag) {
      # v0.12's test driver assume format definition. This simulates ObjectBufferedOutput format
      if !defined?(Fluent::Plugin::Output)
        def format(tag, time, record)
          [time, record].to_msgpack
        end
      end
    }.configure(conf)
  end

  def sample_record
    {'age' => 26, 'request_id' => '42', 'parent_id' => 'parent', 'routing_id' => 'routing'}
  end

  def stub_elastic_ping(url="http://localhost:9200")
    stub_request(:head, url).to_return(:status => 200, :body => "", :headers => {})
  end

  def stub_elastic(url="http://localhost:9200/_bulk")
    stub_request(:post, url).with do |req|
      @index_cmds = req.body.split("\n").map {|r| JSON.parse(r) }
    end
  end

  def stub_elastic_unavailable(url="http://localhost:9200/_bulk")
    stub_request(:post, url).to_return(:status => [503, "Service Unavailable"])
  end

  def stub_elastic_with_store_index_command_counts(url="http://localhost:9200/_bulk")
    if @index_command_counts == nil
       @index_command_counts = {}
       @index_command_counts.default = 0
    end

    stub_request(:post, url).with do |req|
      index_cmds = req.body.split("\n").map {|r| JSON.parse(r) }
      @index_command_counts[url] += index_cmds.size
    end
  end

  def test_configure
    config = %{
      host     logs.google.com
      port     777
      scheme   https
      path     /es/
      user     john
      password doe
    }
    instance = driver('test', config).instance

    conf = instance.dynamic_config
    assert_equal 'logs.google.com', conf['host']
    assert_equal "777", conf['port']
    assert_equal 'john', instance.user
    assert_equal 'doe', instance.password
    assert_equal '/es/', instance.path
    assert_equal :TLSv1, instance.ssl_version
    assert_nil instance.client_key
    assert_nil instance.client_cert
    assert_nil instance.client_key_pass
  end

  def test_defaults
    config = %{
      host     logs.google.com
      scheme   https
      path     /es/
      user     john
      password doe
    }
    instance = driver('test', config).instance

    conf = instance.dynamic_config
    assert_equal "9200", conf['port']
    assert_equal "false", conf['logstash_format']
    assert_equal "true", conf['utc_index']
    assert_equal false, instance.time_key_exclude_timestamp
  end

  def test_legacy_hosts_list
    config = %{
      hosts    host1:50,host2:100,host3
      scheme   https
      path     /es/
      port     123
    }
    instance = driver('test', config).instance

    assert_equal 3, instance.get_connection_options(nil)[:hosts].length
    host1, host2, host3 = instance.get_connection_options(nil)[:hosts]

    assert_equal 'host1', host1[:host]
    assert_equal 50, host1[:port]
    assert_equal 'https', host1[:scheme]
    assert_equal '/es/', host2[:path]
    assert_equal 'host3', host3[:host]
    assert_equal 123, host3[:port]
    assert_equal 'https', host3[:scheme]
    assert_equal '/es/', host3[:path]
  end

  def test_hosts_list
    config = %{
      hosts    https://john:password@host1:443/elastic/,http://host2
      path     /default_path
      user     default_user
      password default_password
    }
    instance = driver('test', config).instance

    assert_equal 2, instance.get_connection_options(nil)[:hosts].length
    host1, host2 = instance.get_connection_options(nil)[:hosts]

    assert_equal 'host1', host1[:host]
    assert_equal 443, host1[:port]
    assert_equal 'https', host1[:scheme]
    assert_equal 'john', host1[:user]
    assert_equal 'password', host1[:password]
    assert_equal '/elastic/', host1[:path]

    assert_equal 'host2', host2[:host]
    assert_equal 'http', host2[:scheme]
    assert_equal 'default_user', host2[:user]
    assert_equal 'default_password', host2[:password]
    assert_equal '/default_path', host2[:path]
  end

  def test_hosts_list_with_escape_placeholders
    config = %{
      hosts    https://%{j+hn}:%{passw@rd}@host1:443/elastic/,http://host2
      path     /default_path
      user     default_user
      password default_password
    }
    instance = driver('test', config).instance

    assert_equal 2, instance.get_connection_options(nil)[:hosts].length
    host1, host2 = instance.get_connection_options(nil)[:hosts]

    assert_equal 'host1', host1[:host]
    assert_equal 443, host1[:port]
    assert_equal 'https', host1[:scheme]
    assert_equal 'j%2Bhn', host1[:user]
    assert_equal 'passw%40rd', host1[:password]
    assert_equal '/elastic/', host1[:path]

    assert_equal 'host2', host2[:host]
    assert_equal 'http', host2[:scheme]
    assert_equal 'default_user', host2[:user]
    assert_equal 'default_password', host2[:password]
    assert_equal '/default_path', host2[:path]
  end

  def test_single_host_params_and_defaults
    config = %{
      host     logs.google.com
      user     john
      password doe
    }
    instance = driver('test', config).instance

    assert_equal 1, instance.get_connection_options(nil)[:hosts].length
    host1 = instance.get_connection_options(nil)[:hosts][0]

    assert_equal 'logs.google.com', host1[:host]
    assert_equal 9200, host1[:port]
    assert_equal 'http', host1[:scheme]
    assert_equal 'john', host1[:user]
    assert_equal 'doe', host1[:password]
    assert_equal nil, host1[:path]
  end

  def test_single_host_params_and_defaults_with_escape_placeholders
    config = %{
      host     logs.google.com
      user     %{j+hn}
      password %{d@e}
    }
    instance = driver('test', config).instance

    assert_equal 1, instance.get_connection_options(nil)[:hosts].length
    host1 = instance.get_connection_options(nil)[:hosts][0]

    assert_equal 'logs.google.com', host1[:host]
    assert_equal 9200, host1[:port]
    assert_equal 'http', host1[:scheme]
    assert_equal 'j%2Bhn', host1[:user]
    assert_equal 'd%40e', host1[:password]
    assert_equal nil, host1[:path]
  end

  def test_content_type_header
    stub_request(:head, "http://localhost:9200/").
      to_return(:status => 200, :body => "", :headers => {})
    elastic_request = stub_request(:post, "http://localhost:9200/_bulk").
      with(headers: { "Content-Type" => "application/json" })
    driver.emit(sample_record)
    driver.run
    assert_requested(elastic_request)
  end

  def test_writes_to_default_index
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert_equal('fluentd', index_cmds.first['index']['_index'])
  end

  def test_writes_to_default_type
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert_equal('fluentd', index_cmds.first['index']['_type'])
  end

  def test_writes_to_specified_index
    driver.configure("index_name myindex\n")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert_equal('myindex', index_cmds.first['index']['_index'])
  end

  def test_writes_to_specified_index_uppercase
    driver.configure("index_name MyIndex\n")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert_equal('myindex', index_cmds.first['index']['_index'])
  end

  def test_writes_to_specified_type
    driver.configure("type_name mytype\n")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert_equal('mytype', index_cmds.first['index']['_type'])
  end

  def test_writes_to_specified_host
    driver.configure("host 192.168.33.50\n")
    stub_elastic_ping("http://192.168.33.50:9200")
    elastic_request = stub_elastic("http://192.168.33.50:9200/_bulk")
    driver.emit(sample_record)
    driver.run
    assert_requested(elastic_request)
  end

  def test_writes_to_specified_port
    driver.configure("port 9201\n")
    stub_elastic_ping("http://localhost:9201")
    elastic_request = stub_elastic("http://localhost:9201/_bulk")
    driver.emit(sample_record)
    driver.run
    assert_requested(elastic_request)
  end

  def test_writes_to_multi_hosts
    hosts = [['192.168.33.50', 9201], ['192.168.33.51', 9201], ['192.168.33.52', 9201]]
    hosts_string = hosts.map {|x| "#{x[0]}:#{x[1]}"}.compact.join(',')

    driver.configure("hosts #{hosts_string}")

    hosts.each do |host_info|
      host, port = host_info
      stub_elastic_ping("http://#{host}:#{port}")
      stub_elastic_with_store_index_command_counts("http://#{host}:#{port}/_bulk")
    end

    1000.times do
      driver.emit(sample_record.merge('age'=>rand(100)))
    end

    driver.run

    # @note: we cannot make multi chunks with options (flush_interval, buffer_chunk_limit)
    # it's Fluentd test driver's constraint
    # so @index_command_counts.size is always 1

    assert(@index_command_counts.size > 0, "not working with hosts options")

    total = 0
    @index_command_counts.each do |url, count|
      total += count
    end
    assert_equal(2000, total)
  end

  class AdditionalHashIdMechanismTest < self
    data("default"            => {"hash_id_key" => '_id'},
         "custom hash_id_key" => {"hash_id_key" => '_hash_id'},
        )
    def test_writes_with_genrate_hash(data)
      assert_raise_message(/Use bundled filter-elasticsearch-genid instead./) do
        driver.configure(Fluent::Config::Element.new(
                           'ROOT', '', {
                             '@type' => 'elasticsearch',
                             'id_key' => data["hash_id_key"],
                           }, [
                             Fluent::Config::Element.new('hash', '', {
                                                           'keys' => ['request_id'],
                                                           'hash_id_key' => data["hash_id_key"],
                                                         }, [])
                           ]
                         ))
      end
    end
  end

  def test_makes_bulk_request
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.emit(sample_record.merge('age' => 27))
    driver.run
    assert_equal(4, index_cmds.count)
  end

  def test_all_records_are_preserved_in_bulk
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.emit(sample_record.merge('age' => 27))
    driver.run
    assert_equal(26, index_cmds[1]['age'])
    assert_equal(27, index_cmds[3]['age'])
  end

  def test_writes_to_logstash_index
    driver.configure("logstash_format true\n")
    time = Time.parse Date.today.to_s
    logstash_index = "logstash-#{time.getutc.strftime("%Y.%m.%d")}"
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record, time.to_i)
    driver.run
    assert_equal(logstash_index, index_cmds.first['index']['_index'])
  end

  def test_writes_to_logstash_utc_index
    driver.configure("logstash_format true
                      utc_index false")
    time = Time.parse Date.today.to_s
    utc_index = "logstash-#{time.strftime("%Y.%m.%d")}"
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record, time.to_i)
    driver.run
    assert_equal(utc_index, index_cmds.first['index']['_index'])
  end

  def test_writes_to_logstash_index_with_specified_prefix
    driver.configure("logstash_format true
                      logstash_prefix myprefix")
    time = Time.parse Date.today.to_s
    logstash_index = "myprefix-#{time.getutc.strftime("%Y.%m.%d")}"
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record, time.to_i)
    driver.run
    assert_equal(logstash_index, index_cmds.first['index']['_index'])
  end

  def test_writes_to_logstash_index_with_specified_prefix_uppercase
    driver.configure("logstash_format true
                      logstash_prefix MyPrefix")
    time = Time.parse Date.today.to_s
    logstash_index = "myprefix-#{time.getutc.strftime("%Y.%m.%d")}"
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record, time.to_i)
    driver.run
    assert_equal(logstash_index, index_cmds.first['index']['_index'])
  end

    def test_writes_to_logstash_index_with_specified_dateformat
    driver.configure("logstash_format true
                      logstash_dateformat %Y.%m")
    time = Time.parse Date.today.to_s
    logstash_index = "logstash-#{time.getutc.strftime("%Y.%m")}"
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record, time.to_i)
    driver.run
    assert_equal(logstash_index, index_cmds.first['index']['_index'])
  end

  def test_writes_to_logstash_index_with_specified_prefix_and_dateformat
    driver.configure("logstash_format true
                      logstash_prefix myprefix
                      logstash_dateformat %Y.%m")
    time = Time.parse Date.today.to_s
    logstash_index = "myprefix-#{time.getutc.strftime("%Y.%m")}"
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record, time.to_i)
    driver.run
    assert_equal(logstash_index, index_cmds.first['index']['_index'])
  end

  def test_doesnt_add_logstash_timestamp_by_default
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert_nil(index_cmds[1]['@timestamp'])
  end

  def test_adds_logstash_timestamp_when_configured
    driver.configure("logstash_format true\n")
    stub_elastic_ping
    stub_elastic
    ts = DateTime.now.to_s
    driver.emit(sample_record)
    driver.run
    assert(index_cmds[1].has_key? '@timestamp')
    assert_equal(index_cmds[1]['@timestamp'], ts)
  end

  def test_uses_custom_timestamp_when_included_in_record
    driver.configure("include_timestamp true\n")
    stub_elastic_ping
    stub_elastic
    ts = DateTime.new(2001,2,3).to_s
    driver.emit(sample_record.merge!('@timestamp' => ts))
    driver.run
    assert(index_cmds[1].has_key? '@timestamp')
    assert_equal(index_cmds[1]['@timestamp'], ts)
  end

  def test_uses_custom_timestamp_when_included_in_record_logstash
    driver.configure("logstash_format true\n")
    stub_elastic_ping
    stub_elastic
    ts = DateTime.new(2001,2,3).to_s
    driver.emit(sample_record.merge!('@timestamp' => ts))
    driver.run
    assert(index_cmds[1].has_key? '@timestamp')
    assert_equal(index_cmds[1]['@timestamp'], ts)
  end

  def test_uses_custom_time_key_logstash
    driver.configure("logstash_format true
                      time_key vtm\n")
    stub_elastic_ping
    stub_elastic
    ts = DateTime.new(2001,2,3).to_s
    driver.emit(sample_record.merge!('vtm' => ts))
    driver.run
    assert(index_cmds[1].has_key? '@timestamp')
    assert_equal(index_cmds[1]['@timestamp'], ts)
  end

  def test_uses_custom_time_key_timestamp
    driver.configure("include_timestamp true
                      time_key vtm\n")
    stub_elastic_ping
    stub_elastic
    ts = DateTime.new(2001,2,3).to_s
    driver.emit(sample_record.merge!('vtm' => ts))
    driver.run
    assert(index_cmds[1].has_key? '@timestamp')
    assert_equal(index_cmds[1]['@timestamp'], ts)
  end

  def test_uses_custom_time_key_timestamp_custom_index
    driver.configure("include_timestamp true
                      index_name test
                      time_key vtm\n")
    stub_elastic_ping
    stub_elastic
    ts = DateTime.new(2001,2,3).to_s
    driver.emit(sample_record.merge!('vtm' => ts))
    driver.run
    assert(index_cmds[1].has_key? '@timestamp')
    assert_equal(index_cmds[1]['@timestamp'], ts)
    assert_equal('test', index_cmds.first['index']['_index'])
  end

  def test_uses_custom_time_key_exclude_timestamp
    driver.configure("include_timestamp true
                      time_key vtm
                      time_key_exclude_timestamp true\n")
    stub_elastic_ping
    stub_elastic
    ts = DateTime.new(2001,2,3).to_s
    driver.emit(sample_record.merge!('vtm' => ts))
    driver.run
    assert(!index_cmds[1].key?('@timestamp'), '@timestamp should be missing')
  end

  def test_uses_custom_time_key_exclude_timestamp_logstash
    driver.configure("logstash_format true
                      time_key vtm
                      time_key_exclude_timestamp true\n")
    stub_elastic_ping
    stub_elastic
    ts = DateTime.new(2001,2,3).to_s
    driver.emit(sample_record.merge!('vtm' => ts))
    driver.run
    assert(!index_cmds[1].key?('@timestamp'), '@timestamp should be missing')
  end

  def test_doesnt_add_tag_key_by_default
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert_nil(index_cmds[1]['tag'])
  end

  def test_adds_tag_key_when_configured
    driver('mytag').configure("include_tag_key true\n")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert(index_cmds[1].has_key?('tag'))
    assert_equal(index_cmds[1]['tag'], 'mytag')
  end

  def test_adds_id_key_when_configured
    driver.configure("id_key request_id\n")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert_equal(index_cmds[0]['index']['_id'], '42')
  end

  def test_doesnt_add_id_key_if_missing_when_configured
    driver.configure("id_key another_request_id\n")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert(!index_cmds[0]['index'].has_key?('_id'))
  end

  def test_adds_id_key_when_not_configured
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert(!index_cmds[0]['index'].has_key?('_id'))
  end

  def test_adds_parent_key_when_configured
    driver.configure("parent_key parent_id\n")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert_equal(index_cmds[0]['index']['_parent'], 'parent')
  end

  def test_doesnt_add_parent_key_if_missing_when_configured
    driver.configure("parent_key another_parent_id\n")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert(!index_cmds[0]['index'].has_key?('_parent'))
  end

  def test_adds_parent_key_when_not_configured
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert(!index_cmds[0]['index'].has_key?('_parent'))
  end

  def test_adds_routing_key_when_configured
    driver.configure("routing_key routing_id\n")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert_equal(index_cmds[0]['index']['_routing'], 'routing')
  end

  def test_doesnt_add_routing_key_if_missing_when_configured
    driver.configure("routing_key another_routing_id\n")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert(!index_cmds[0]['index'].has_key?('_routing'))
  end

  def test_adds_routing_key_when_not_configured
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert(!index_cmds[0]['index'].has_key?('_routing'))
  end

  def test_remove_one_key
    driver.configure("remove_keys key1\n")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record.merge('key1' => 'v1', 'key2' => 'v2'))
    driver.run
    assert(!index_cmds[1].has_key?('key1'))
    assert(index_cmds[1].has_key?('key2'))
  end

  def test_remove_multi_keys
    driver.configure("remove_keys key1, key2\n")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record.merge('key1' => 'v1', 'key2' => 'v2'))
    driver.run
    assert(!index_cmds[1].has_key?('key1'))
    assert(!index_cmds[1].has_key?('key2'))
  end

  def test_request_error
    stub_elastic_ping
    stub_elastic_unavailable
    driver.emit(sample_record)
    assert_raise(Elasticsearch::Transport::Transport::Errors::ServiceUnavailable) {
      driver.run
    }
  end

  def test_garbage_record_error
    stub_elastic_ping
    stub_elastic
    driver.emit("some garbage string")
    driver.run
  end

  def test_tag_parts_index_error_event
    stub_elastic_ping
    stub_elastic
    driver.configure("logstash_prefix ${tag_parts[1]}\n")
    flexmock(driver.instance.router).should_receive(:emit_error_event)
      .with('test', Integer, Hash, TypeError).once
    driver.emit(sample_record)
    driver.run
  end

  def test_connection_failed_retry
    connection_resets = 0

    stub_elastic_ping(url="http://localhost:9200").with do |req|
      connection_resets += 1
    end

    stub_request(:post, "http://localhost:9200/_bulk").with do |req|
      raise Faraday::ConnectionFailed, "Test message"
    end

    driver.emit(sample_record)

    assert_raise(Fluent::ElasticsearchOutput::ConnectionFailure) {
      driver.run
    }
    assert_equal(connection_resets, 3)
  end

  def test_reconnect_on_error_enabled
    connection_resets = 0

    stub_elastic_ping(url="http://localhost:9200").with do |req|
      connection_resets += 1
    end

    stub_request(:post, "http://localhost:9200/_bulk").with do |req|
      raise ZeroDivisionError, "any not host_unreachable_exceptions exception"
    end

    driver.configure("reconnect_on_error true\n")
    driver.emit(sample_record)

    assert_raise(ZeroDivisionError) {
      driver.run
    }

    assert_raise(ZeroDivisionError) {
      driver.run
    }
    assert_equal(connection_resets, 2)
  end

  def test_reconnect_on_error_disabled
    connection_resets = 0

    stub_elastic_ping(url="http://localhost:9200").with do |req|
      connection_resets += 1
    end

    stub_request(:post, "http://localhost:9200/_bulk").with do |req|
      raise ZeroDivisionError, "any not host_unreachable_exceptions exception"
    end

    driver.configure("reconnect_on_error false\n")
    driver.emit(sample_record)

    assert_raise(ZeroDivisionError) {
      driver.run
    }

    assert_raise(ZeroDivisionError) {
      driver.run
    }
    assert_equal(connection_resets, 1)
  end

  def test_update_should_not_write_if_theres_no_id
    driver.configure("write_operation update\n")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert_nil(index_cmds)
  end

  def test_upsert_should_not_write_if_theres_no_id
    driver.configure("write_operation upsert\n")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert_nil(index_cmds)
  end

  def test_create_should_not_write_if_theres_no_id
    driver.configure("write_operation create\n")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert_nil(index_cmds)
  end

  def test_update_should_write_update_op_and_doc_as_upsert_is_false
    driver.configure("write_operation update
                      id_key request_id")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert(index_cmds[0].has_key?("update"))
    assert(!index_cmds[1]["doc_as_upsert"])
  end

  def test_upsert_should_write_update_op_and_doc_as_upsert_is_true
    driver.configure("write_operation upsert
                      id_key request_id")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert(index_cmds[0].has_key?("update"))
    assert(index_cmds[1]["doc_as_upsert"])
  end

  def test_create_should_write_create_op
    driver.configure("write_operation create
                      id_key request_id")
    stub_elastic_ping
    stub_elastic
    driver.emit(sample_record)
    driver.run
    assert(index_cmds[0].has_key?("create"))
  end
end

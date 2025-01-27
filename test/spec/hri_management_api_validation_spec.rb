# (C) Copyright IBM Corp. 2020
#
# SPDX-License-Identifier: Apache-2.0

require_relative '../env'

describe 'HRI Management API With Validation' do

  INVALID_ID = 'INVALID'
  TENANT_ID = ENV['TENANT_ID']
  INTEGRATOR_ID = 'claims'
  TEST_TENANT_ID = "rspec-#{ENV['TRAVIS_BRANCH'].delete('.')}-test-tenant".downcase
  TEST_INTEGRATOR_ID = "rspec-#{ENV['TRAVIS_BRANCH'].delete('.')}-test-integrator".downcase
  DATA_TYPE = 'rspec-batch'
  STATUS = 'started'
  BATCH_INPUT_TOPIC = "ingest.#{TENANT_ID}.#{INTEGRATOR_ID}.in"
  KAFKA_TIMEOUT = 60
  INVALID_THRESHOLD = 5
  INVALID_RECORD_COUNT = 3
  ACTUAL_RECORD_COUNT = 15
  EXPECTED_RECORD_COUNT = 15
  FAILURE_MESSAGE = 'Rspec Failure Message'

  before(:all) do
    @hri_base_url = ENV['HRI_URL']
    @request_helper = HRITestHelpers::RequestHelper.new
    @elastic = HRITestHelpers::ElasticHelper.new({url: ENV['ELASTIC_URL'], username: ENV['ELASTIC_USERNAME'], password: ENV['ELASTIC_PASSWORD']})
    @iam_token = HRITestHelpers::IAMHelper.new(ENV['IAM_CLOUD_URL']).get_access_token(ENV['CLOUD_API_KEY'])
    @mgmt_api_helper = HRITestHelpers::MgmtAPIHelper.new(@hri_base_url, @iam_token)
    @hri_deploy_helper = HRIDeployHelper.new
    @event_streams_helper = HRITestHelpers::EventStreamsHelper.new
    @app_id_helper = HRITestHelpers::AppIDHelper.new(ENV['APPID_URL'], ENV['APPID_TENANT'], @iam_token, ENV['JWT_AUDIENCE_ID'])
    @start_date = DateTime.now

    @exe_path = File.absolute_path(File.join(File.dirname(__FILE__), "../../src/hri"))
    @config_path = File.absolute_path(File.join(File.dirname(__FILE__), "test_config"))
    @log_path = File.absolute_path(File.join(File.dirname(__FILE__), "/"))

    @hri_deploy_helper.deploy_hri(@exe_path, "#{@config_path}/valid_config.yml", @log_path, '-validation true')
    response = @request_helper.rest_get("#{@hri_base_url}/healthcheck", {})
    unless response.code == 200
      raise "Health check failed: #{response.body}"
    end

    #Initialize Kafka Consumer
    @kafka = Kafka.new(ENV['KAFKA_BROKERS'], sasl_plain_username: 'token', sasl_plain_password: ENV['KAFKA_PASSWORD'], ssl_ca_certs_from_system: true)
    @kafka_consumer = @kafka.consumer(group_id: 'rspec-mgmt-api-consumer')
    @kafka_consumer.subscribe("ingest.#{TENANT_ID}.#{INTEGRATOR_ID}.notification")

    #Create Batch
    @batch_prefix = "rspec-#{ENV['TRAVIS_BRANCH'].delete('.')}"
    @batch_name = "#{@batch_prefix}-#{SecureRandom.uuid}"
    create_batch = {
      name: @batch_name,
      status: STATUS,
      recordCount: 1,
      dataType: DATA_TYPE,
      topic: BATCH_INPUT_TOPIC,
      startDate: @start_date,
      metadata: {
        rspec1: 'test1',
        rspec2: 'test2',
        rspec3: {
          rspec3A: 'test3A',
          rspec3B: 'test3B'
        }
      }
    }.to_json
    response = @elastic.es_create_batch(TENANT_ID, create_batch)
    expect(response.code).to eq 201
    parsed_response = JSON.parse(response.body)
    @batch_id = parsed_response['_id']
    Logger.new(STDOUT).info("New Batch Created With ID: #{@batch_id}")

    #Get AppId Access Tokens
    @token_invalid_tenant = @app_id_helper.get_access_token('hri_integration_tenant_test_invalid', 'tenant_test_invalid')
    @token_no_roles = @app_id_helper.get_access_token('hri_integration_tenant_test', 'tenant_test')
    @token_integrator_role_only = @app_id_helper.get_access_token('hri_integration_tenant_test_data_integrator', 'tenant_test hri_data_integrator')
    @token_consumer_role_only = @app_id_helper.get_access_token('hri_integration_tenant_test_data_consumer', 'tenant_test hri_consumer')
    @token_all_roles = @app_id_helper.get_access_token('hri_integration_tenant_test_integrator_consumer', 'tenant_test hri_data_integrator hri_consumer')
    @token_internal_role_only = @app_id_helper.get_access_token('hri_integration_tenant_test_internal', 'tenant_test hri_internal')
    @token_invalid_audience = @app_id_helper.get_access_token('hri_integration_tenant_test_integrator_consumer', 'tenant_test hri_data_integrator hri_consumer', ENV['APPID_TENANT'])
  end

  after(:all) do
    File.delete("#{@log_path}/output.txt") if File.exists?("#{@log_path}/output.txt")
    File.delete("#{@log_path}/error.txt") if File.exists?("#{@log_path}/error.txt")

    processes = `lsof -iTCP:1323 -sTCP:LISTEN`
    unless processes == ''
      process_id = processes.split("\n").select { |s| s.start_with?('hri') }[0].split(' ')[1].to_i
      `kill #{process_id}` unless process_id.nil?
    end

    #Delete Batches
    response = @elastic.es_delete_by_query(TENANT_ID, "name:rspec-#{ENV['TRAVIS_BRANCH']}*")
    response.nil? ? (raise 'Elastic batch delete did not return a response') : (expect(response.code).to eq 200)
    Logger.new(STDOUT).info("Delete test batches by query response #{response.body}")

    @kafka_consumer.stop
  end

  context 'POST /tenants/{tenant_id}/streams/{integrator_id}' do

    before(:all) do
      @stream_info = {
        numPartitions: 1,
        retentionMs: 3600000
      }
    end

    it 'Success' do
      #Create Tenant
      response = @mgmt_api_helper.hri_post_tenant(TEST_TENANT_ID)
      expect(response.code).to eq 201
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['tenantId']).to eql TEST_TENANT_ID

      #Create Stream
      response = @mgmt_api_helper.hri_post_tenant_stream(TEST_TENANT_ID, TEST_INTEGRATOR_ID, @stream_info.to_json)
      expect(response.code).to eq 201

      #Verify Stream Creation
      response = @mgmt_api_helper.hri_get_tenant_streams(TEST_TENANT_ID)
      expect(response.code).to eq 200
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['results'][0]['id']).to eql TEST_INTEGRATOR_ID

      Timeout.timeout(30, nil, 'Kafka topics not created after 30 seconds') do
        loop do
          topics = @event_streams_helper.get_topics
          break if (topics.include?("ingest.#{TEST_TENANT_ID}.#{TEST_INTEGRATOR_ID}.in") &&
                    topics.include?("ingest.#{TEST_TENANT_ID}.#{TEST_INTEGRATOR_ID}.notification") &&
                    topics.include?("ingest.#{TEST_TENANT_ID}.#{TEST_INTEGRATOR_ID}.out") &&
                    topics.include?("ingest.#{TEST_TENANT_ID}.#{TEST_INTEGRATOR_ID}.invalid"))
        end
      end
    end

  end

  context 'DELETE /tenants/{tenant_id}/streams/{integrator_id}' do

    it 'Success' do
      #Delete Stream
      response = @mgmt_api_helper.hri_delete_tenant_stream(TEST_TENANT_ID, TEST_INTEGRATOR_ID)
      expect(response.code).to eq 200

      #Verify Stream Deletion
      response = @mgmt_api_helper.hri_get_tenant_streams(TEST_TENANT_ID)
      expect(response.code).to eq 200
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['results']).to eql []

      #Delete Tenant
      response = @mgmt_api_helper.hri_delete_tenant(TEST_TENANT_ID)
      expect(response.code).to eq 200

      #Verify Tenant Deleted
      response = @mgmt_api_helper.hri_get_tenant(TEST_TENANT_ID)
      expect(response.code).to eq 404
    end

  end

  context 'PUT /tenants/{tenantId}/batches/{batchId}/action/sendComplete' do

    before(:all) do
      @expected_record_count = {
        expectedRecordCount: EXPECTED_RECORD_COUNT,
        metadata: {
          rspec1: 'test3',
          rspec2: 'test4',
          rspec4: {
            rspec4A: 'test4A',
            rspec4B: 'テスト'
          }
        }
      }
      @batch_template = {
        name: @batch_name,
        dataType: DATA_TYPE,
        topic: BATCH_INPUT_TOPIC,
        invalidThreshold: INVALID_THRESHOLD,
        metadata: {
          rspec1: 'test1',
          rspec2: 'test2',
          rspec3: {
            rspec3A: 'test3A',
            rspec3B: 'test3B'
          }
        }
      }
    end

    it 'Success' do
      #Create Batch
      response = @mgmt_api_helper.hri_post_batch(TENANT_ID, @batch_template.to_json, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 201
      expect(response.headers[:'content_security_policy']).to eql "default-src 'none'; script-src 'none'; connect-src 'self'; img-src 'self'; style-src 'self';"
      expect(response.headers[:'x_content_type_options']).to eql 'nosniff'
      expect(response.headers[:'x_xss_protection']).to eql '1'
      parsed_response = JSON.parse(response.body)
      @send_complete_batch_id = parsed_response['id']
      Logger.new(STDOUT).info("New Send Complete Batch Created With ID: #{@send_complete_batch_id}")

      #Set Batch to Send Completed
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @send_complete_batch_id, 'sendComplete', @expected_record_count, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 200

      #Verify Batch Send Completed
      response = @mgmt_api_helper.hri_get_batch(TENANT_ID, @send_complete_batch_id, {'Authorization' => "Bearer #{@token_consumer_role_only}"})
      expect(response.code).to eq 200
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['status']).to eql 'sendCompleted'
      expect(parsed_response['endDate']).to be_nil
      expect(parsed_response['expectedRecordCount']).to eq EXPECTED_RECORD_COUNT
      expect(parsed_response['recordCount']).to eq EXPECTED_RECORD_COUNT

      #Verify Kafka Message
      Timeout.timeout(KAFKA_TIMEOUT) do
        Logger.new(STDOUT).info("Waiting for a Kafka message with Batch ID: #{@send_complete_batch_id} and status: sendCompleted")
        @kafka_consumer.each_message do |message|
          parsed_message = JSON.parse(message.value)
          if parsed_message['id'] == @send_complete_batch_id && parsed_message['status'] == 'sendCompleted'
            @message_found = true
            expect(parsed_message['dataType']).to eql DATA_TYPE
            expect(parsed_message['id']).to eql @send_complete_batch_id
            expect(parsed_message['name']).to eql @batch_name
            expect(parsed_message['topic']).to eql BATCH_INPUT_TOPIC
            expect(parsed_message['invalidThreshold']).to eql INVALID_THRESHOLD
            expect(parsed_message['expectedRecordCount']).to eq EXPECTED_RECORD_COUNT
            expect(parsed_message['recordCount']).to eq EXPECTED_RECORD_COUNT
            expect(DateTime.parse(parsed_message['startDate']).strftime("%Y-%m-%d")).to eq Date.today.strftime("%Y-%m-%d")
            expect(parsed_message['metadata']['rspec1']).to eql 'test3'
            expect(parsed_message['metadata']['rspec2']).to eql 'test4'
            expect(parsed_message['metadata']['rspec4']['rspec4A']).to eql 'test4A'
            expect(parsed_message['metadata']['rspec4']['rspec4B']).to eql 'テスト'
            expect(parsed_message['metadata']['rspec3']).to be_nil
            break
          end
        end
        expect(@message_found).to be true
      end
    end

    it 'Invalid Tenant ID' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @batch_id, 'sendComplete', @expected_record_count, {'Authorization' => "Bearer #{@token_invalid_tenant}"})
      expect(response.code).to eq 401
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "Unauthorized tenant access. Tenant '#{TENANT_ID}' is not included in the authorized scopes: ."
    end

    it 'Invalid Batch ID' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, INVALID_ID, 'sendComplete', @expected_record_count, {'Authorization' => "Bearer #{@token_all_roles}"})
      expect(response.code).to eq 404
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "error getting current Batch Status: The document for tenantId: #{TENANT_ID} with document (batch) ID: #{INVALID_ID} was not found"
    end

    it 'Missing Record Count' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @batch_id, 'sendComplete', nil, {'Authorization' => "Bearer #{@token_all_roles}"})
      expect(response.code).to eq 400
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "invalid request arguments:\n- expectedRecordCount (json field in request body) must be present if recordCount (json field in request body) is not present\n- recordCount (json field in request body) must be present if expectedRecordCount (json field in request body) is not present"
    end

    it 'Invalid Record Count' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @batch_id, 'sendComplete', {expectedRecordCount: "1"}, {'Authorization' => "Bearer #{@token_all_roles}"})
      expect(response.code).to eq 400
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "invalid request param \"expectedRecordCount\": expected type int, but received type string"
    end

    it 'Missing Tenant ID' do
      response = @mgmt_api_helper.hri_put_batch(nil, @batch_id, 'sendComplete', @expected_record_count, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 400
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "invalid request arguments:\n- tenantId (url path parameter) is a required field"
    end

    it 'Missing Batch ID' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, nil, 'sendComplete', @expected_record_count, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 400
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "invalid request arguments:\n- id (url path parameter) is a required field"
    end

    it 'Missing Batch ID and Record Count' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, nil, 'sendComplete', nil, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 400
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "invalid request arguments:\n- expectedRecordCount (json field in request body) must be present if recordCount (json field in request body) is not present\n- id (url path parameter) is a required field\n- recordCount (json field in request body) must be present if expectedRecordCount (json field in request body) is not present"
    end

    it 'Conflict: Batch with a status of completed' do
      #Create Batch
      response = @mgmt_api_helper.hri_post_batch(TENANT_ID, @batch_template.to_json, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 201
      parsed_response = JSON.parse(response.body)
      @send_complete_batch_id = parsed_response['id']
      Logger.new(STDOUT).info("New Send Complete Batch Created With ID: #{@send_complete_batch_id}")

      #Update Batch to Completed Status
      update_batch_script = {
        script: {
          source: 'ctx._source.status = params.status',
          lang: 'painless',
          params: {
            status: 'completed'
          }
        }
      }.to_json
      response = @elastic.es_batch_update(TENANT_ID, @send_complete_batch_id, update_batch_script)
      response.nil? ? (raise 'Elastic batch update did not return a response') : (expect(response.code).to eq 200)
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['result']).to eql 'updated'
      Logger.new(STDOUT).info('Batch status updated to "completed"')

      #Verify Batch Status Updated
      response = @elastic.es_get_batch(TENANT_ID, @send_complete_batch_id)
      response.nil? ? (raise 'Elastic get batch did not return a response') : (expect(response.code).to eq 200)
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['_source']['status']).to eql 'completed'

      #Attempt to send complete batch
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @send_complete_batch_id, 'sendComplete', @expected_record_count, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 409
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "sendComplete failed, batch is in 'completed' state"
    end

    it 'Conflict: Batch with a status of terminated' do
      #Create Batch
      response = @mgmt_api_helper.hri_post_batch(TENANT_ID, @batch_template.to_json, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 201
      parsed_response = JSON.parse(response.body)
      @send_complete_batch_id = parsed_response['id']
      Logger.new(STDOUT).info("New Send Complete Batch Created With ID: #{@send_complete_batch_id}")

      #Update Batch to Terminated Status
      update_batch_script = {
        script: {
          source: 'ctx._source.status = params.status',
          lang: 'painless',
          params: {
            status: 'terminated'
          }
        }
      }.to_json
      response = @elastic.es_batch_update(TENANT_ID, @send_complete_batch_id, update_batch_script)
      response.nil? ? (raise 'Elastic batch update did not return a response') : (expect(response.code).to eq 200)
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['result']).to eql 'updated'
      Logger.new(STDOUT).info('Batch status updated to "terminated"')

      #Verify Batch Status Updated
      response = @elastic.es_get_batch(TENANT_ID, @send_complete_batch_id)
      response.nil? ? (raise 'Elastic get batch did not return a response') : (expect(response.code).to eq 200)
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['_source']['status']).to eql 'terminated'

      #Attempt to send complete batch
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @send_complete_batch_id, 'sendComplete', @expected_record_count, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 409
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "sendComplete failed, batch is in 'terminated' state"
    end

    it 'Conflict: Batch with a status of failed' do
      #Create Batch
      response = @mgmt_api_helper.hri_post_batch(TENANT_ID, @batch_template.to_json, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 201
      parsed_response = JSON.parse(response.body)
      @send_complete_batch_id = parsed_response['id']
      Logger.new(STDOUT).info("New Send Complete Batch Created With ID: #{@send_complete_batch_id}")

      #Update Batch to Failed Status
      update_batch_script = {
        script: {
          source: 'ctx._source.status = params.status',
          lang: 'painless',
          params: {
            status: 'failed'
          }
        }
      }.to_json
      response = @elastic.es_batch_update(TENANT_ID, @send_complete_batch_id, update_batch_script)
      response.nil? ? (raise 'Elastic batch update did not return a response') : (expect(response.code).to eq 200)
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['result']).to eql 'updated'
      Logger.new(STDOUT).info('Batch status updated to "failed"')

      #Verify Batch Status Updated
      response = @elastic.es_get_batch(TENANT_ID, @send_complete_batch_id)
      response.nil? ? (raise 'Elastic get batch did not return a response') : (expect(response.code).to eq 200)
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['_source']['status']).to eql 'failed'

      #Attempt to send complete batch
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @send_complete_batch_id, 'sendComplete', @expected_record_count, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 409
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "sendComplete failed, batch is in 'failed' state"
    end

    it 'Conflict: Batch that already has a sendCompleted status' do
      #Create Batch
      response = @mgmt_api_helper.hri_post_batch(TENANT_ID, @batch_template.to_json, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 201
      parsed_response = JSON.parse(response.body)
      @send_complete_batch_id = parsed_response['id']
      Logger.new(STDOUT).info("New Send Complete Batch Created With ID: #{@send_complete_batch_id}")

      #Update Batch to Completed Status
      update_batch_script = {
        script: {
          source: 'ctx._source.status = params.status',
          lang: 'painless',
          params: {
            status: 'sendCompleted'
          }
        }
      }.to_json
      response = @elastic.es_batch_update(TENANT_ID, @send_complete_batch_id, update_batch_script)
      response.nil? ? (raise 'Elastic batch update did not return a response') : (expect(response.code).to eq 200)
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['result']).to eql 'updated'
      Logger.new(STDOUT).info('Batch status updated to "sendCompleted"')

      #Verify Batch Status Updated
      response = @elastic.es_get_batch(TENANT_ID, @send_complete_batch_id)
      response.nil? ? (raise 'Elastic get batch did not return a response') : (expect(response.code).to eq 200)
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['_source']['status']).to eql 'sendCompleted'

      #Attempt to send complete batch
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @send_complete_batch_id, 'sendComplete', @expected_record_count, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 409
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "sendComplete failed, batch is in 'sendCompleted' state"
    end

    it 'Unauthorized - Missing Authorization' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @batch_id, 'sendComplete', @expected_record_count)
      expect(response.code).to eq 401
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql 'Authorization token validation failed: oidc: malformed jwt: square/go-jose: compact JWS format must have three parts'
    end

    it 'Unauthorized - Invalid Tenant ID' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @batch_id, 'sendComplete', @expected_record_count, {'Authorization' => "Bearer #{@token_invalid_tenant}"})
      expect(response.code).to eq 401
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "Unauthorized tenant access. Tenant '#{TENANT_ID}' is not included in the authorized scopes: ."
    end

    it 'Unauthorized - No Roles' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @batch_id, 'sendComplete', @expected_record_count, {'Authorization' => "Bearer #{@token_no_roles}"})
      expect(response.code).to eq 401
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql 'Must have hri_data_integrator role to initiate sendComplete on a batch'
    end

    it 'Unauthorized - Consumer Role Can Not Update Batch Status' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @batch_id, 'sendComplete', @expected_record_count, {'Authorization' => "Bearer #{@token_consumer_role_only}"})
      expect(response.code).to eq 401
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql 'Must have hri_data_integrator role to initiate sendComplete on a batch'
    end

    it 'Unauthorized - Invalid Audience' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @batch_id, 'sendComplete', @expected_record_count, {'Authorization' => "Bearer #{@token_invalid_audience}"})
      expect(response.code).to eq 401
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "Authorization token validation failed: oidc: expected audience \"#{ENV['JWT_AUDIENCE_ID']}\" got [\"#{ENV['APPID_TENANT']}\"]"
    end

  end

  context 'PUT /tenants/{tenantId}/batches/{batchId}/action/processingComplete' do

    before(:all) do
      @record_counts = {
        invalidRecordCount: INVALID_RECORD_COUNT,
        actualRecordCount: ACTUAL_RECORD_COUNT
      }
      @batch_template = {
        name: @batch_name,
        dataType: DATA_TYPE,
        topic: BATCH_INPUT_TOPIC,
        invalidThreshold: INVALID_THRESHOLD,
        metadata: {
          rspec1: 'test1',
          rspec2: 'test2',
          rspec3: {
            rspec3A: 'test3A',
            rspec3B: 'test3B'
          }
        }
      }
    end

    it 'Success' do
      #Create Batch
      response = @mgmt_api_helper.hri_post_batch(TENANT_ID, @batch_template.to_json, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 201
      parsed_response = JSON.parse(response.body)
      @processing_complete_batch_id = parsed_response['id']
      Logger.new(STDOUT).info("New Processing Complete Batch Created With ID: #{@processing_complete_batch_id}")

      #Update Batch to sendCompleted Status
      update_batch_script = {
        script: {
          source: 'ctx._source.status = params.status',
          lang: 'painless',
          params: {
            status: 'sendCompleted'
          }
        }
      }.to_json
      response = @elastic.es_batch_update(TENANT_ID, @processing_complete_batch_id, update_batch_script)
      response.nil? ? (raise 'Elastic batch update did not return a response') : (expect(response.code).to eq 200)
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['result']).to eql 'updated'
      Logger.new(STDOUT).info('Batch status updated to "sendCompleted"')

      #Verify Batch Status Updated
      response = @elastic.es_get_batch(TENANT_ID, @processing_complete_batch_id)
      response.nil? ? (raise 'Elastic get batch did not return a response') : (expect(response.code).to eq 200)
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['_source']['status']).to eql 'sendCompleted'

      #Set Batch to Completed
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @processing_complete_batch_id, 'processingComplete', @record_counts, {'Authorization' => "Bearer #{@token_internal_role_only}"})
      expect(response.code).to eq 200

      #Verify Batch Processing Completed
      response = @mgmt_api_helper.hri_get_batch(TENANT_ID, @processing_complete_batch_id, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 200
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['status']).to eql 'completed'
      expect(parsed_response['endDate']).to_not be_nil
      expect(parsed_response['invalidRecordCount']).to eq INVALID_RECORD_COUNT

      #Verify Kafka Message
      Timeout.timeout(KAFKA_TIMEOUT) do
        Logger.new(STDOUT).info("Waiting for a Kafka message with Batch ID: #{@processing_complete_batch_id} and status: completed")
        @kafka_consumer.each_message do |message|
          parsed_message = JSON.parse(message.value)
          if parsed_message['id'] == @processing_complete_batch_id && parsed_message['status'] == 'completed'
            @message_found = true
            expect(parsed_message['dataType']).to eql DATA_TYPE
            expect(parsed_message['id']).to eql @processing_complete_batch_id
            expect(parsed_message['name']).to eql @batch_name
            expect(parsed_message['topic']).to eql BATCH_INPUT_TOPIC
            expect(parsed_message['invalidThreshold']).to eql INVALID_THRESHOLD
            expect(parsed_message['invalidRecordCount']).to eql INVALID_RECORD_COUNT
            expect(parsed_message['actualRecordCount']).to eql ACTUAL_RECORD_COUNT
            expect(DateTime.parse(parsed_message['startDate']).strftime("%Y-%m-%d")).to eq Date.today.strftime("%Y-%m-%d")
            expect(DateTime.parse(parsed_message['endDate']).strftime("%Y-%m-%d")).to eq Date.today.strftime("%Y-%m-%d")
            expect(parsed_message['metadata']['rspec1']).to eql 'test1'
            expect(parsed_message['metadata']['rspec2']).to eql 'test2'
            expect(parsed_message['metadata']['rspec3']['rspec3A']).to eql 'test3A'
            expect(parsed_message['metadata']['rspec3']['rspec3B']).to eql 'test3B'
            break
          end
        end
        expect(@message_found).to be true
      end
    end

    it 'Invalid Tenant ID' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @batch_id, 'processingComplete', @record_counts, {'Authorization' => "Bearer #{@token_invalid_tenant}"})
      expect(response.code).to eq 401
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "Unauthorized tenant access. Tenant '#{TENANT_ID}' is not included in the authorized scopes: ."
    end

    it 'Invalid Batch ID' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, INVALID_ID, 'processingComplete', @record_counts, {'Authorization' => "Bearer #{@token_internal_role_only}"})
      expect(response.code).to eq 404
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "error getting current Batch Status: The document for tenantId: #{TENANT_ID} with document (batch) ID: #{INVALID_ID} was not found"
    end

    it 'Missing invalidRecordCount' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @batch_id, 'processingComplete', {actualRecordCount: ACTUAL_RECORD_COUNT}, {'Authorization' => "Bearer #{@token_internal_role_only}"})
      expect(response.code).to eq 400
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "invalid request arguments:\n- invalidRecordCount (json field in request body) is a required field"
    end

    it 'Invalid invalidRecordCount' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @batch_id, 'processingComplete', {invalidRecordCount: "1", actualRecordCount: ACTUAL_RECORD_COUNT}, {'Authorization' => "Bearer #{@token_internal_role_only}"})
      expect(response.code).to eq 400
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "invalid request param \"invalidRecordCount\": expected type int, but received type string"
    end

    it 'Missing actualRecordCount' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @batch_id, 'processingComplete', {invalidRecordCount: INVALID_RECORD_COUNT}, {'Authorization' => "Bearer #{@token_internal_role_only}"})
      expect(response.code).to eq 400
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "invalid request arguments:\n- actualRecordCount (json field in request body) is a required field"
    end

    it 'Invalid actualRecordCount' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @batch_id, 'processingComplete', {actualRecordCount: "1", invalidRecordCount: INVALID_RECORD_COUNT}, {'Authorization' => "Bearer #{@token_internal_role_only}"})
      expect(response.code).to eq 400
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "invalid request param \"actualRecordCount\": expected type int, but received type string"
    end

    it 'Missing Tenant ID' do
      response = @mgmt_api_helper.hri_put_batch(nil, @batch_id, 'processingComplete', @record_counts, {'Authorization' => "Bearer #{@token_internal_role_only}"})
      expect(response.code).to eq 400
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "invalid request arguments:\n- tenantId (url path parameter) is a required field"
    end

    it 'Missing Batch ID' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, nil, 'processingComplete', @record_counts, {'Authorization' => "Bearer #{@token_internal_role_only}"})
      expect(response.code).to eq 400
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "invalid request arguments:\n- id (url path parameter) is a required field"
    end

    it 'Missing Batch ID and actualRecordCount' do
      @record_counts.delete(:actualRecordCount)
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, nil, 'processingComplete', @record_counts, {'Authorization' => "Bearer #{@token_internal_role_only}"})
      expect(response.code).to eq 400
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "invalid request arguments:\n- actualRecordCount (json field in request body) is a required field\n- id (url path parameter) is a required field"
      @record_counts[:actualRecordCount] = ACTUAL_RECORD_COUNT
    end

    it 'Conflict: Batch with a status of started' do
      #Create Batch
      response = @mgmt_api_helper.hri_post_batch(TENANT_ID, @batch_template.to_json, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 201
      parsed_response = JSON.parse(response.body)
      @processing_complete_batch_id = parsed_response['id']
      Logger.new(STDOUT).info("New Processing Complete Batch Created With ID: #{@processing_complete_batch_id}")

      #Attempt to process complete batch
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @processing_complete_batch_id, 'processingComplete', @record_counts, {'Authorization' => "Bearer #{@token_internal_role_only}"})
      expect(response.code).to eq 409
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "processingComplete failed, batch is in 'started' state"
    end

    it 'Conflict: Batch with a status of terminated' do
      #Create Batch
      response = @mgmt_api_helper.hri_post_batch(TENANT_ID, @batch_template.to_json, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 201
      parsed_response = JSON.parse(response.body)
      @processing_complete_batch_id = parsed_response['id']
      Logger.new(STDOUT).info("New Processing Complete Batch Created With ID: #{@processing_complete_batch_id}")

      #Update Batch to Terminated Status
      update_batch_script = {
        script: {
          source: 'ctx._source.status = params.status',
          lang: 'painless',
          params: {
            status: 'terminated'
          }
        }
      }.to_json
      response = @elastic.es_batch_update(TENANT_ID, @processing_complete_batch_id, update_batch_script)
      response.nil? ? (raise 'Elastic batch update did not return a response') : (expect(response.code).to eq 200)
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['result']).to eql 'updated'
      Logger.new(STDOUT).info('Batch status updated to "terminated"')

      #Verify Batch Status Updated
      response = @elastic.es_get_batch(TENANT_ID, @processing_complete_batch_id)
      response.nil? ? (raise 'Elastic get batch did not return a response') : (expect(response.code).to eq 200)
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['_source']['status']).to eql 'terminated'

      #Attempt to process complete batch
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @processing_complete_batch_id, 'processingComplete', @record_counts, {'Authorization' => "Bearer #{@token_internal_role_only}"})
      expect(response.code).to eq 409
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "processingComplete failed, batch is in 'terminated' state"
    end

    it 'Conflict: Batch with a status of failed' do
      #Create Batch
      response = @mgmt_api_helper.hri_post_batch(TENANT_ID, @batch_template.to_json, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 201
      parsed_response = JSON.parse(response.body)
      @processing_complete_batch_id = parsed_response['id']
      Logger.new(STDOUT).info("New Processing Complete Batch Created With ID: #{@processing_complete_batch_id}")

      #Update Batch to Failed Status
      update_batch_script = {
        script: {
          source: 'ctx._source.status = params.status',
          lang: 'painless',
          params: {
            status: 'failed'
          }
        }
      }.to_json
      response = @elastic.es_batch_update(TENANT_ID, @processing_complete_batch_id, update_batch_script)
      response.nil? ? (raise 'Elastic batch update did not return a response') : (expect(response.code).to eq 200)
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['result']).to eql 'updated'
      Logger.new(STDOUT).info('Batch status updated to "failed"')

      #Verify Batch Status Updated
      response = @elastic.es_get_batch(TENANT_ID, @processing_complete_batch_id)
      response.nil? ? (raise 'Elastic get batch did not return a response') : (expect(response.code).to eq 200)
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['_source']['status']).to eql 'failed'

      #Attempt to process complete batch
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @processing_complete_batch_id, 'processingComplete', @record_counts, {'Authorization' => "Bearer #{@token_internal_role_only}"})
      expect(response.code).to eq 409
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "processingComplete failed, batch is in 'failed' state"
    end

    it 'Conflict: Batch that already has a completed status' do
      #Create Batch
      response = @mgmt_api_helper.hri_post_batch(TENANT_ID, @batch_template.to_json, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 201
      parsed_response = JSON.parse(response.body)
      @processing_complete_batch_id = parsed_response['id']
      Logger.new(STDOUT).info("New Processing Complete Batch Created With ID: #{@processing_complete_batch_id}")

      #Update Batch to Completed Status
      update_batch_script = {
        script: {
          source: 'ctx._source.status = params.status',
          lang: 'painless',
          params: {
            status: 'completed'
          }
        }
      }.to_json
      response = @elastic.es_batch_update(TENANT_ID, @processing_complete_batch_id, update_batch_script)
      response.nil? ? (raise 'Elastic batch update did not return a response') : (expect(response.code).to eq 200)
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['result']).to eql 'updated'
      Logger.new(STDOUT).info('Batch status updated to "completed"')

      #Verify Batch Status Updated
      response = @elastic.es_get_batch(TENANT_ID, @processing_complete_batch_id)
      response.nil? ? (raise 'Elastic get batch did not return a response') : (expect(response.code).to eq 200)
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['_source']['status']).to eql 'completed'

      #Attempt to process complete batch
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @processing_complete_batch_id, 'processingComplete', @record_counts, {'Authorization' => "Bearer #{@token_internal_role_only}"})
      expect(response.code).to eq 409
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "processingComplete failed, batch is in 'completed' state"
    end

    it 'Unauthorized - Missing Authorization' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @batch_id, 'processingComplete', @record_counts)
      expect(response.code).to eq 401
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql 'Authorization token validation failed: oidc: malformed jwt: square/go-jose: compact JWS format must have three parts'
    end

    it 'Unauthorized - Invalid Authorization' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @batch_id, 'processingComplete', @record_counts, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 401
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql 'Must have hri_internal role to mark a batch as processingComplete'
    end

    it 'Unauthorized - Invalid Tenant ID' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @batch_id, 'processingComplete', @record_counts, {'Authorization' => "Bearer #{@token_invalid_tenant}"})
      expect(response.code).to eq 401
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "Unauthorized tenant access. Tenant '#{TENANT_ID}' is not included in the authorized scopes: ."
    end

    it 'Unauthorized - Invalid Audience' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @batch_id, 'processingComplete', @record_counts, {'Authorization' => "Bearer #{@token_invalid_audience}"})
      expect(response.code).to eq 401
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "Authorization token validation failed: oidc: expected audience \"#{ENV['JWT_AUDIENCE_ID']}\" got [\"#{ENV['APPID_TENANT']}\"]"
    end

  end

  context 'PUT /tenants/{tenantId}/batches/{batchId}/action/terminate' do

    before(:all) do
      @batch_template = {
        name: @batch_name,
        dataType: DATA_TYPE,
        topic: BATCH_INPUT_TOPIC,
        invalidThreshold: INVALID_THRESHOLD,
        metadata: {
          rspec1: 'test1',
          rspec2: 'test2',
          rspec3: {
            rspec3A: 'test3A',
            rspec3B: 'test3B'
          }
        }
      }
      @terminate_metadata = {
        metadata: {
          rspec1: 'test3',
          rspec2: 'test4',
          rspec4: {
            rspec4A: 'test4A',
            rspec4B: 'テスト'
          }
        }
      }
    end

    it 'Success' do
      #Create Batch
      response = @mgmt_api_helper.hri_post_batch(TENANT_ID, @batch_template.to_json, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 201
      parsed_response = JSON.parse(response.body)
      @terminate_batch_id = parsed_response['id']
      Logger.new(STDOUT).info("New Terminate Batch Created With ID: #{@terminate_batch_id}")

      #Terminate Batch
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @terminate_batch_id, 'terminate', @terminate_metadata, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 200

      #Verify Batch Terminated
      response = @mgmt_api_helper.hri_get_batch(TENANT_ID, @terminate_batch_id, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 200
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['status']).to eql 'terminated'
      expect(parsed_response['endDate']).to_not be_nil

      #Verify Kafka Message
      Timeout.timeout(KAFKA_TIMEOUT) do
        Logger.new(STDOUT).info("Waiting for a Kafka message with Batch ID: #{@terminate_batch_id} and status: terminated")
        @kafka_consumer.each_message do |message|
          parsed_message = JSON.parse(message.value)
          if parsed_message['id'] == @terminate_batch_id && parsed_message['status'] == 'terminated'
            @message_found = true
            expect(parsed_message['dataType']).to eql DATA_TYPE
            expect(parsed_message['id']).to eql @terminate_batch_id
            expect(parsed_message['name']).to eql @batch_name
            expect(parsed_message['topic']).to eql BATCH_INPUT_TOPIC
            expect(parsed_message['invalidThreshold']).to eql INVALID_THRESHOLD
            expect(DateTime.parse(parsed_message['startDate']).strftime("%Y-%m-%d")).to eq Date.today.strftime("%Y-%m-%d")
            expect(DateTime.parse(parsed_message['endDate']).strftime("%Y-%m-%d")).to eq Date.today.strftime("%Y-%m-%d")
            expect(parsed_message['metadata']['rspec1']).to eql 'test3'
            expect(parsed_message['metadata']['rspec2']).to eql 'test4'
            expect(parsed_message['metadata']['rspec4']['rspec4A']).to eql 'test4A'
            expect(parsed_message['metadata']['rspec4']['rspec4B']).to eql 'テスト'
            expect(parsed_message['metadata']['rspec3']).to be_nil
            break
          end
        end
        expect(@message_found).to be true
      end
    end

    it 'Invalid Tenant ID' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @batch_id, 'terminate', nil, {'Authorization' => "Bearer #{@token_invalid_tenant}"})
      expect(response.code).to eq 401
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "Unauthorized tenant access. Tenant '#{TENANT_ID}' is not included in the authorized scopes: ."
    end

    it 'Invalid Batch ID' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, INVALID_ID, 'terminate', nil, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 404
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "error getting current Batch Status: The document for tenantId: #{TENANT_ID} with document (batch) ID: #{INVALID_ID} was not found"
    end

    it 'Missing Tenant ID' do
      response = @mgmt_api_helper.hri_put_batch(nil, @batch_id, 'terminate', @terminate_metadata, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 400
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "invalid request arguments:\n- tenantId (url path parameter) is a required field"
    end

    it 'Missing Batch ID' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, nil, 'terminate', @terminate_metadata, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 400
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "invalid request arguments:\n- id (url path parameter) is a required field"
    end

    it 'Conflict: Batch with a status of sendCompleted' do
      #Create Batch
      response = @mgmt_api_helper.hri_post_batch(TENANT_ID, @batch_template.to_json, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 201
      parsed_response = JSON.parse(response.body)
      @terminate_batch_id = parsed_response['id']
      Logger.new(STDOUT).info("New Terminate Batch Created With ID: #{@terminate_batch_id}")

      #Update Batch to sendCompleted Status
      update_batch_script = {
        script: {
          source: 'ctx._source.status = params.status',
          lang: 'painless',
          params: {
            status: 'sendCompleted'
          }
        }
      }.to_json
      response = @elastic.es_batch_update(TENANT_ID, @terminate_batch_id, update_batch_script)
      response.nil? ? (raise 'Elastic batch update did not return a response') : (expect(response.code).to eq 200)
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['result']).to eql 'updated'
      Logger.new(STDOUT).info('Batch status updated to "sendCompleted"')

      #Verify Batch Status Updated
      response = @elastic.es_get_batch(TENANT_ID, @terminate_batch_id)
      response.nil? ? (raise 'Elastic get batch did not return a response') : (expect(response.code).to eq 200)
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['_source']['status']).to eql 'sendCompleted'

      #Attempt to terminate batch
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @terminate_batch_id, 'terminate', nil, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 409
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "terminate failed, batch is in 'sendCompleted' state"
    end

    it 'Conflict: Batch with a status of completed' do
      #Create Batch
      response = @mgmt_api_helper.hri_post_batch(TENANT_ID, @batch_template.to_json, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 201
      parsed_response = JSON.parse(response.body)
      @terminate_batch_id = parsed_response['id']
      Logger.new(STDOUT).info("New Terminate Batch Created With ID: #{@terminate_batch_id}")

      #Update Batch to Completed Status
      update_batch_script = {
        script: {
          source: 'ctx._source.status = params.status',
          lang: 'painless',
          params: {
            status: 'completed'
          }
        }
      }.to_json
      response = @elastic.es_batch_update(TENANT_ID, @terminate_batch_id, update_batch_script)
      response.nil? ? (raise 'Elastic batch update did not return a response') : (expect(response.code).to eq 200)
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['result']).to eql 'updated'
      Logger.new(STDOUT).info('Batch status updated to "completed"')

      #Verify Batch Status Updated
      response = @elastic.es_get_batch(TENANT_ID, @terminate_batch_id)
      response.nil? ? (raise 'Elastic get batch did not return a response') : (expect(response.code).to eq 200)
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['_source']['status']).to eql 'completed'

      #Attempt to terminate batch
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @terminate_batch_id, 'terminate', nil, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 409
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "terminate failed, batch is in 'completed' state"
    end

    it 'Conflict: Batch with a status of failed' do
      #Create Batch
      response = @mgmt_api_helper.hri_post_batch(TENANT_ID, @batch_template.to_json, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 201
      parsed_response = JSON.parse(response.body)
      @terminate_batch_id = parsed_response['id']
      Logger.new(STDOUT).info("New Terminate Batch Created With ID: #{@terminate_batch_id}")

      #Update Batch to Failed Status
      update_batch_script = {
        script: {
          source: 'ctx._source.status = params.status',
          lang: 'painless',
          params: {
            status: 'failed'
          }
        }
      }.to_json
      response = @elastic.es_batch_update(TENANT_ID, @terminate_batch_id, update_batch_script)
      response.nil? ? (raise 'Elastic batch update did not return a response') : (expect(response.code).to eq 200)
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['result']).to eql 'updated'
      Logger.new(STDOUT).info('Batch status updated to "failed"')

      #Verify Batch Status Updated
      response = @elastic.es_get_batch(TENANT_ID, @terminate_batch_id)
      response.nil? ? (raise 'Elastic get batch did not return a response') : (expect(response.code).to eq 200)
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['_source']['status']).to eql 'failed'

      #Attempt to terminate batch
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @terminate_batch_id, 'terminate', nil, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 409
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "terminate failed, batch is in 'failed' state"
    end

    it 'Conflict: Batch that already has a terminated status' do
      #Create Batch
      response = @mgmt_api_helper.hri_post_batch(TENANT_ID, @batch_template.to_json, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 201
      parsed_response = JSON.parse(response.body)
      @terminate_batch_id = parsed_response['id']
      Logger.new(STDOUT).info("New Terminate Batch Created With ID: #{@terminate_batch_id}")

      #Update Batch to Terminated Status
      update_batch_script = {
        script: {
          source: 'ctx._source.status = params.status',
          lang: 'painless',
          params: {
            status: 'terminated'
          }
        }
      }.to_json
      response = @elastic.es_batch_update(TENANT_ID, @terminate_batch_id, update_batch_script)
      response.nil? ? (raise 'Elastic batch update did not return a response') : (expect(response.code).to eq 200)
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['result']).to eql 'updated'
      Logger.new(STDOUT).info('Batch status updated to "terminated"')

      #Verify Batch Status Updated
      response = @elastic.es_get_batch(TENANT_ID, @terminate_batch_id)
      response.nil? ? (raise 'Elastic get batch did not return a response') : (expect(response.code).to eq 200)
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['_source']['status']).to eql 'terminated'

      #Attempt to terminate batch
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @terminate_batch_id, 'terminate', nil, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 409
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "terminate failed, batch is in 'terminated' state"
    end

    it 'Unauthorized - Missing Authorization' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @batch_id, 'terminate', nil)
      expect(response.code).to eq 401
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql 'Authorization token validation failed: oidc: malformed jwt: square/go-jose: compact JWS format must have three parts'
    end

    it 'Unauthorized - Invalid Tenant ID' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @batch_id, 'terminate', nil, {'Authorization' => "Bearer #{@token_invalid_tenant}"})
      expect(response.code).to eq 401
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "Unauthorized tenant access. Tenant '#{TENANT_ID}' is not included in the authorized scopes: ."
    end

    it 'Unauthorized - No Roles' do
      #Create Batch
      response = @mgmt_api_helper.hri_post_batch(TENANT_ID, @batch_template.to_json, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 201
      parsed_response = JSON.parse(response.body)
      @terminate_batch_id = parsed_response['id']
      Logger.new(STDOUT).info("New Terminate Batch Created With ID: #{@terminate_batch_id}")

      #Attempt to terminate batch
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @terminate_batch_id, 'terminate', nil, {'Authorization' => "Bearer #{@token_no_roles}"})
      expect(response.code).to eq 401
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql 'Must have hri_data_integrator role to terminate a batch'
    end

    it 'Unauthorized - Consumer Role Can Not Update Batch Status' do
      #Create Batch
      response = @mgmt_api_helper.hri_post_batch(TENANT_ID, @batch_template.to_json, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 201
      parsed_response = JSON.parse(response.body)
      @terminate_batch_id = parsed_response['id']
      Logger.new(STDOUT).info("New Terminate Batch Created With ID: #{@terminate_batch_id}")

      #Attempt to terminate batch
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @terminate_batch_id, 'terminate', nil, {'Authorization' => "Bearer #{@token_consumer_role_only}"})
      expect(response.code).to eq 401
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql 'Must have hri_data_integrator role to terminate a batch'
    end

    it 'Unauthorized - Invalid Audience' do
      #Create Batch
      response = @mgmt_api_helper.hri_post_batch(TENANT_ID, @batch_template.to_json, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 201
      parsed_response = JSON.parse(response.body)
      @terminate_batch_id = parsed_response['id']
      Logger.new(STDOUT).info("New Terminate Batch Created With ID: #{@terminate_batch_id}")

      #Attempt to terminate batch
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @terminate_batch_id, 'terminate', nil, {'Authorization' => "Bearer #{@token_invalid_audience}"})
      expect(response.code).to eq 401
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "Authorization token validation failed: oidc: expected audience \"#{ENV['JWT_AUDIENCE_ID']}\" got [\"#{ENV['APPID_TENANT']}\"]"
    end

  end

  context 'PUT /tenants/{tenantId}/batches/{batchId}/action/fail' do

    before(:all) do
      @record_counts_and_message = {
        actualRecordCount: ACTUAL_RECORD_COUNT,
        failureMessage: FAILURE_MESSAGE,
        invalidRecordCount: INVALID_RECORD_COUNT
      }
      @batch_template = {
        name: @batch_name,
        dataType: DATA_TYPE,
        topic: BATCH_INPUT_TOPIC,
        invalidThreshold: INVALID_THRESHOLD,
        metadata: {
          rspec1: 'test1',
          rspec2: 'test2',
          rspec3: {
            rspec3A: 'test3A',
            rspec3B: 'テスト'
          }
        }
      }
    end

    it 'Success' do
      #Create Batch
      response = @mgmt_api_helper.hri_post_batch(TENANT_ID, @batch_template.to_json, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 201
      parsed_response = JSON.parse(response.body)
      @failed_batch_id = parsed_response['id']
      Logger.new(STDOUT).info("New Failed Batch Created With ID: #{@failed_batch_id}")

      #Update Batch to Completed Status
      update_batch_script = {
        script: {
          source: 'ctx._source.status = params.status',
          lang: 'painless',
          params: {
            status: 'completed'
          }
        }
      }.to_json
      response = @elastic.es_batch_update(TENANT_ID, @failed_batch_id, update_batch_script)
      response.nil? ? (raise 'Elastic batch update did not return a response') : (expect(response.code).to eq 200)
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['result']).to eql 'updated'
      Logger.new(STDOUT).info('Batch status updated to "completed"')

      #Verify Batch Status Updated
      response = @elastic.es_get_batch(TENANT_ID, @failed_batch_id)
      response.nil? ? (raise 'Elastic get batch did not return a response') : (expect(response.code).to eq 200)
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['_source']['status']).to eql 'completed'

      #Set Batch to Failed
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @failed_batch_id, 'fail', @record_counts_and_message, {'Authorization' => "Bearer #{@token_internal_role_only}"})
      expect(response.code).to eq 200

      #Verify Batch Failed
      response = @mgmt_api_helper.hri_get_batch(TENANT_ID, @failed_batch_id, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 200
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['status']).to eql 'failed'
      expect(parsed_response['endDate']).to_not be_nil
      expect(parsed_response['invalidRecordCount']).to eq INVALID_RECORD_COUNT

      #Verify Kafka Message
      Timeout.timeout(KAFKA_TIMEOUT) do
        Logger.new(STDOUT).info("Waiting for a Kafka message with Batch ID: #{@failed_batch_id} and status: failed")
        @kafka_consumer.each_message do |message|
          parsed_message = JSON.parse(message.value)
          if parsed_message['id'] == @failed_batch_id && parsed_message['status'] == 'failed'
            @message_found = true
            expect(parsed_message['dataType']).to eql DATA_TYPE
            expect(parsed_message['id']).to eql @failed_batch_id
            expect(parsed_message['name']).to eql @batch_name
            expect(parsed_message['topic']).to eql BATCH_INPUT_TOPIC
            expect(parsed_message['invalidThreshold']).to eql INVALID_THRESHOLD
            expect(parsed_message['invalidRecordCount']).to eql INVALID_RECORD_COUNT
            expect(parsed_message['actualRecordCount']).to eql ACTUAL_RECORD_COUNT
            expect(parsed_message['failureMessage']).to eql FAILURE_MESSAGE
            expect(DateTime.parse(parsed_message['startDate']).strftime("%Y-%m-%d")).to eq Date.today.strftime("%Y-%m-%d")
            expect(DateTime.parse(parsed_message['endDate']).strftime("%Y-%m-%d")).to eq Date.today.strftime("%Y-%m-%d")
            expect(parsed_message['metadata']['rspec1']).to eql 'test1'
            expect(parsed_message['metadata']['rspec2']).to eql 'test2'
            expect(parsed_message['metadata']['rspec3']['rspec3A']).to eql 'test3A'
            expect(parsed_message['metadata']['rspec3']['rspec3B']).to eql 'テスト'
            break
          end
        end
        expect(@message_found).to be true
      end
    end

    it 'Invalid Tenant ID' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @batch_id, 'fail', @record_counts_and_message, {'Authorization' => "Bearer #{@token_invalid_tenant}"})
      expect(response.code).to eq 401
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "Unauthorized tenant access. Tenant '#{TENANT_ID}' is not included in the authorized scopes: ."
    end

    it 'Invalid Batch ID' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, INVALID_ID, 'fail', @record_counts_and_message, {'Authorization' => "Bearer #{@token_internal_role_only}"})
      expect(response.code).to eq 404
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "error getting current Batch Status: The document for tenantId: #{TENANT_ID} with document (batch) ID: #{INVALID_ID} was not found"
    end

    it 'Missing invalidRecordCount' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @batch_id, 'fail', {actualRecordCount: ACTUAL_RECORD_COUNT, failureMessage: 'RSpec failure message'}, {'Authorization' => "Bearer #{@token_internal_role_only}"})
      expect(response.code).to eq 400
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "invalid request arguments:\n- invalidRecordCount (json field in request body) is a required field"
    end

    it 'Invalid invalidRecordCount' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @batch_id, 'fail', {invalidRecordCount: "1", actualRecordCount: ACTUAL_RECORD_COUNT, failureMessage: 'RSpec failure message'}, {'Authorization' => "Bearer #{@token_internal_role_only}"})
      expect(response.code).to eq 400
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "invalid request param \"invalidRecordCount\": expected type int, but received type string"
    end

    it 'Missing actualRecordCount' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @batch_id, 'fail', {invalidRecordCount: INVALID_RECORD_COUNT, failureMessage: 'RSpec failure message'}, {'Authorization' => "Bearer #{@token_internal_role_only}"})
      expect(response.code).to eq 400
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "invalid request arguments:\n- actualRecordCount (json field in request body) is a required field"
    end

    it 'Invalid actualRecordCount' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @batch_id, 'fail', {actualRecordCount: "1", invalidRecordCount: INVALID_RECORD_COUNT, failureMessage: 'RSpec failure message'}, {'Authorization' => "Bearer #{@token_internal_role_only}"})
      expect(response.code).to eq 400
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "invalid request param \"actualRecordCount\": expected type int, but received type string"
    end

    it 'Missing failureMessage' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @batch_id, 'fail', {actualRecordCount: ACTUAL_RECORD_COUNT, invalidRecordCount: INVALID_RECORD_COUNT}, {'Authorization' => "Bearer #{@token_internal_role_only}"})
      expect(response.code).to eq 400
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "invalid request arguments:\n- failureMessage (json field in request body) is a required field"
    end

    it 'Invalid failureMessage' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @batch_id, 'fail', {invalidRecordCount: INVALID_RECORD_COUNT, actualRecordCount: ACTUAL_RECORD_COUNT, failureMessage: 10}, {'Authorization' => "Bearer #{@token_internal_role_only}"})
      expect(response.code).to eq 400
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "invalid request param \"failureMessage\": expected type string, but received type number"
    end

    it 'Missing Tenant ID' do
      response = @mgmt_api_helper.hri_put_batch(nil, @batch_id, 'fail', @record_counts_and_message, {'Authorization' => "Bearer #{@token_internal_role_only}"})
      expect(response.code).to eq 400
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "invalid request arguments:\n- tenantId (url path parameter) is a required field"
    end

    it 'Missing Batch ID' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, nil, 'fail', @record_counts_and_message, {'Authorization' => "Bearer #{@token_internal_role_only}"})
      expect(response.code).to eq 400
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "invalid request arguments:\n- id (url path parameter) is a required field"
    end

    it 'Missing Batch ID and failureMessage' do
      @record_counts_and_message.delete(:failureMessage)
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, nil, 'fail', @record_counts_and_message, {'Authorization' => "Bearer #{@token_internal_role_only}"})
      expect(response.code).to eq 400
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "invalid request arguments:\n- failureMessage (json field in request body) is a required field\n- id (url path parameter) is a required field"
      @record_counts_and_message[:failureMessage] = FAILURE_MESSAGE
    end

    it 'Conflict: Batch with a status of terminated' do
      #Create Batch
      response = @mgmt_api_helper.hri_post_batch(TENANT_ID, @batch_template.to_json, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 201
      parsed_response = JSON.parse(response.body)
      @failed_batch_id = parsed_response['id']
      Logger.new(STDOUT).info("New Failed Batch Created With ID: #{@failed_batch_id}")

      #Update Batch to Terminated Status
      update_batch_script = {
        script: {
          source: 'ctx._source.status = params.status',
          lang: 'painless',
          params: {
            status: 'terminated'
          }
        }
      }.to_json
      response = @elastic.es_batch_update(TENANT_ID, @failed_batch_id, update_batch_script)
      response.nil? ? (raise 'Elastic batch update did not return a response') : (expect(response.code).to eq 200)
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['result']).to eql 'updated'
      Logger.new(STDOUT).info('Batch status updated to "terminated"')

      #Verify Batch Status Updated
      response = @elastic.es_get_batch(TENANT_ID, @failed_batch_id)
      response.nil? ? (raise 'Elastic get batch did not return a response') : (expect(response.code).to eq 200)
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['_source']['status']).to eql 'terminated'

      #Attempt to fail batch
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @failed_batch_id, 'fail', @record_counts_and_message, {'Authorization' => "Bearer #{@token_internal_role_only}"})
      expect(response.code).to eq 409
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "'fail' failed, batch is in 'terminated' state"
    end

    it 'Conflict: Batch that already has a failed status' do
      #Create Batch
      response = @mgmt_api_helper.hri_post_batch(TENANT_ID, @batch_template.to_json, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 201
      parsed_response = JSON.parse(response.body)
      @failed_batch_id = parsed_response['id']
      Logger.new(STDOUT).info("New Failed Batch Created With ID: #{@failed_batch_id}")

      #Update Batch to Failed Status
      update_batch_script = {
        script: {
          source: 'ctx._source.status = params.status',
          lang: 'painless',
          params: {
            status: 'failed'
          }
        }
      }.to_json
      response = @elastic.es_batch_update(TENANT_ID, @failed_batch_id, update_batch_script)
      response.nil? ? (raise 'Elastic batch update did not return a response') : (expect(response.code).to eq 200)
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['result']).to eql 'updated'
      Logger.new(STDOUT).info('Batch status updated to "failed"')

      #Verify Batch Status Updated
      response = @elastic.es_get_batch(TENANT_ID, @failed_batch_id)
      response.nil? ? (raise 'Elastic get batch did not return a response') : (expect(response.code).to eq 200)
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['_source']['status']).to eql 'failed'

      #Attempt to fail batch
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @failed_batch_id, 'fail', @record_counts_and_message, {'Authorization' => "Bearer #{@token_internal_role_only}"})
      expect(response.code).to eq 409
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "'fail' failed, batch is in 'failed' state"
    end

    it 'Unauthorized - Missing Authorization' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @batch_id, 'fail', @record_counts_and_message)
      expect(response.code).to eq 401
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql 'Authorization token validation failed: oidc: malformed jwt: square/go-jose: compact JWS format must have three parts'
    end

    it 'Unauthorized - Invalid Authorization' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @batch_id, 'fail', @record_counts_and_message, {'Authorization' => "Bearer #{@token_integrator_role_only}"})
      expect(response.code).to eq 401
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql 'Must have hri_internal role to mark a batch as failed'
    end

    it 'Unauthorized - Invalid Tenant ID' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @batch_id, 'fail', @record_counts_and_message, {'Authorization' => "Bearer #{@token_invalid_tenant}"})
      expect(response.code).to eq 401
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "Unauthorized tenant access. Tenant '#{TENANT_ID}' is not included in the authorized scopes: ."
    end

    it 'Unauthorized - Invalid Audience' do
      response = @mgmt_api_helper.hri_put_batch(TENANT_ID, @batch_id, 'fail', @record_counts_and_message, {'Authorization' => "Bearer #{@token_invalid_audience}"})
      expect(response.code).to eq 401
      parsed_response = JSON.parse(response.body)
      expect(parsed_response['errorDescription']).to eql "Authorization token validation failed: oidc: expected audience \"#{ENV['JWT_AUDIENCE_ID']}\" got [\"#{ENV['APPID_TENANT']}\"]"
    end

  end

end
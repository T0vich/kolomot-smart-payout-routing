# frozen_string_literal: true

require_relative 'test_helper'
require 'tempfile'

class LoadersTest < Minitest::Test
  include TestHelper

  def with_file(content, ext: '.json')
    file = Tempfile.new(['smart_routing', ext])
    file.write(content)
    file.close
    yield file.path
  ensure
    file&.unlink
  end

  def test_missing_file_reports_path
    error = assert_raises(SmartRouting::InputError) { SmartRouting::Loaders.operations('нет-такого.json') }
    assert_includes error.message, 'нет-такого.json'
  end

  def test_broken_json_reports_reason
    with_file('{ это не json') do |path|
      error = assert_raises(SmartRouting::InvalidDataError) { SmartRouting::Loaders.operations(path) }
      assert_includes error.message, 'не является корректным JSON'
    end
  end

  def test_operation_without_id_is_rejected
    with_file('[{"amount": 100}]') do |path|
      error = assert_raises(SmartRouting::InvalidDataError) { SmartRouting::Loaders.operations(path) }
      assert_includes error.message, 'operation_id'
    end
  end

  def test_operation_with_invalid_amount_is_rejected
    with_file('[{"operation_id": "op_1", "amount": "много"}]') do |path|
      error = assert_raises(SmartRouting::InvalidDataError) { SmartRouting::Loaders.operations(path) }
      assert_includes error.message, 'amount'
    end
  end

  def test_negative_amount_is_rejected
    with_file('[{"operation_id": "op_1", "amount": -5}]') do |path|
      assert_raises(SmartRouting::InvalidDataError) { SmartRouting::Loaders.operations(path) }
    end
  end

  def test_duplicate_operation_ids_are_rejected
    with_file('[{"operation_id":"op_1","amount":100},{"operation_id":"op_1","amount":200}]') do |path|
      error = assert_raises(SmartRouting::InvalidDataError) { SmartRouting::Loaders.operations(path) }
      assert_includes error.message, 'повторяются'
    end
  end

  def test_single_object_queue_is_accepted
    with_file('{"operation_id": "op_1", "amount": 100}') do |path|
      assert_equal 1, SmartRouting::Loaders.operations(path).size
    end
  end

  def test_providers_without_array_are_rejected
    with_file('{"providers": "не массив"}') do |path|
      error = assert_raises(SmartRouting::InvalidDataError) do
        SmartRouting::Loaders.providers(path, build_config)
      end
      assert_includes error.message, 'providers'
    end
  end

  def test_empty_provider_list_is_rejected
    with_file('{"providers": []}') do |path|
      assert_raises(SmartRouting::InvalidDataError) { SmartRouting::Loaders.providers(path, build_config) }
    end
  end

  def test_provider_without_required_field_is_rejected
    with_file('[{"payment_system": "alpha"}]') do |path|
      error = assert_raises(SmartRouting::InvalidDataError) do
        SmartRouting::Loaders.providers(path, build_config)
      end
      assert_includes error.message, 'status'
    end
  end

  def test_duplicate_providers_are_rejected
    payload = '[{"payment_system":"a","status":"active"},{"payment_system":"a","status":"active"}]'
    with_file(payload) do |path|
      error = assert_raises(SmartRouting::InvalidDataError) do
        SmartRouting::Loaders.providers(path, build_config)
      end
      assert_includes error.message, 'дублируются'
    end
  end

  def test_real_case_files_load
    config = SmartRouting::Config.load
    providers = SmartRouting::Loaders.providers(File.join(TestHelper::DATA_DIR, 'providers.json'), config)
    operations = SmartRouting::Loaders.operations(File.join(TestHelper::DATA_DIR, 'operations_queue_10.json'))

    assert_equal 4, providers.size
    assert_equal 10, operations.size
  end
end

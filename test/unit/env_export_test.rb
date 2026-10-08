# frozen_string_literal: true

require_relative "../test_helper"

class EnvExportTest < Minitest::Test
  KEY = "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAAexample\nBBBBexample\n-----END OPENSSH PRIVATE KEY-----"

  def setup = @gh = TestSupport::GithubFiles.new
  def teardown = @gh.cleanup

  def export(vars: "", secrets: "")
    CiDeploy::EnvExport.new(github: @gh.github).call(vars_json: vars, secrets_json: secrets)
  end

  def test_multiline_secrets_survive_intact_and_are_masked_line_by_line
    export(secrets: JSON.generate("SSH_DEPLOY_KEY" => KEY))
    assert_equal KEY, @gh.exported["SSH_DEPLOY_KEY"]
    KEY.each_line(chomp: true) { |line| assert_includes @gh.log, "::add-mask::#{line}\n" }
  end

  def test_a_value_cannot_inject_another_variable
    payload = "x\nINJECTED<<EOF\nboom\nEOF\nCI_DEPLOY_EOF_fake"
    export(secrets: JSON.generate("APP_SECRET" => payload))
    assert_equal({ "APP_SECRET" => payload }, @gh.exported)
  end

  def test_variables_are_exported_unmasked_and_non_strings_as_json
    export(vars: JSON.generate("APP_HOST" => "app.example.com", "WORKERS" => 3, "FLAGS" => { "a" => true }))
    assert_equal({ "APP_HOST" => "app.example.com", "WORKERS" => "3", "FLAGS" => '{"a":true}' }, @gh.exported)
    refute_includes @gh.log, "add-mask"
  end

  def test_secrets_win_over_variables_of_the_same_name
    export(vars: JSON.generate("TOKEN" => "plain"), secrets: JSON.generate("TOKEN" => "secret"))
    assert_equal "secret", @gh.exported["TOKEN"]
  end

  def test_reserved_names_are_not_exported
    result = export(vars: JSON.generate("PATH" => "/tmp", "BUNDLE_GEMFILE" => "/tmp/Gemfile", "CI_DEPLOY_HOME" => "/tmp",
                                        "GITHUB_TOKEN" => "x", "LD_PRELOAD" => "/tmp/x.so", "RUBYOPT" => "-r/tmp/x", "OK" => "1"))
    assert_equal ["OK"], result.exported
    assert_equal %w[PATH BUNDLE_GEMFILE CI_DEPLOY_HOME GITHUB_TOKEN LD_PRELOAD RUBYOPT], result.skipped
    assert_equal({ "OK" => "1" }, @gh.exported)
  end

  def test_invalid_json_fails_without_echoing_the_content
    error = assert_raises(ArgumentError) { export(secrets: '{"API_KEY": "super-secret-value"') }
    refute_includes error.message, "super-secret-value"
  end

  def test_null_values_are_skipped
    export(vars: '{"A": null, "B": "b"}')
    assert_equal({ "B" => "b" }, @gh.exported)
  end
end

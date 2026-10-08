# frozen_string_literal: true

require_relative "../test_helper"

class RunnerTest < Minitest::Test
  def test_runs_an_argument_vector_without_a_shell_and_captures_output_and_status
    out = StringIO.new
    marker = File.join(tmpdir, "pwned")
    argv = ["sh", "-c", 'printf "%s|" "$@"; exit 3', "x", "a b", "; touch #{marker}", "--version=v1"]
    result = CiDeploy::Runner.new(out: out).run(*argv)
    assert_equal 3, result.status
    assert_equal "a b|; touch #{marker}|--version=v1|", result.output
    refute File.exist?(marker)
    echoed = out.string.lines.first.chomp
    assert_equal argv, Shellwords.split(echoed.delete_prefix("+ ")), "the echoed command must read back as the same argv"
    assert echoed.end_with?(" --version=v1"), "plain words stay unquoted"
  end

  def test_quiet_and_echo_options
    out = StringIO.new
    CiDeploy::Runner.new(out: out).run("echo", "hidden", echo: false, quiet: true)
    assert_equal "", out.string
  end

  def test_a_missing_executable_reports_127
    result = CiDeploy::Runner.new(out: StringIO.new).run("ci-deploy-no-such-command")
    assert_equal 127, result.status
  end

  def test_runs_in_the_given_directory_with_extra_environment
    result = CiDeploy::Runner.new(out: StringIO.new, chdir: tmpdir, env: { "CI_DEPLOY_TEST_VALUE" => "multi\nline" })
                             .run("sh", "-c", 'pwd; printf "%s" "$CI_DEPLOY_TEST_VALUE"')
    assert_equal "#{File.realpath(tmpdir)}\nmulti\nline", result.output.sub(tmpdir, File.realpath(tmpdir))
  end
end

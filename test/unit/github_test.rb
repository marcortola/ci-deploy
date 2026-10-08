# frozen_string_literal: true

require_relative "../test_helper"

class GithubTest < Minitest::Test
  def setup = @gh = TestSupport::GithubFiles.new
  def teardown = @gh.cleanup

  def test_mask_escapes_percent_and_carriage_return_as_command_data
    @gh.github.mask("p%ss\rword")
    assert_equal "::add-mask::p%25ss%0Dword\n", @gh.log
  end

  def test_mask_keeps_an_already_escaped_looking_value_literal
    @gh.github.mask("x%0Ay")
    assert_equal "::add-mask::x%250Ay\n", @gh.log
  end

  def test_mask_splits_lines_and_drops_crlf_endings
    @gh.github.mask("first\r\nsecond%\n\n")
    assert_equal "::add-mask::first\n::add-mask::second%25\n", @gh.log
  end
end

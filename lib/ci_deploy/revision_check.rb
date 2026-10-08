# frozen_string_literal: true

require "open3"

module CiDeploy
  # Checks that a component consumes this repository at exactly one revision.
  #
  # - Every reference lives in a top-level workflow (.github/workflows/*.yml or *.yaml). Every file
  #   git knows about (tracked, or untracked and not ignored) is scanned: a local action under
  #   .github/workflows/shared/, or a script anywhere else, that referenced this repository would be
  #   a second pin that Dependabot's workflow-directory entry never updates. GitHub matches owner
  #   and repository names case-insensitively, so this check does too.
  # - Every reference is pinned to a full 40-character commit SHA, and all of them to the same one,
  #   so setup, deploy, operations and their helpers run the same code.
  # - Release comments on those references, when present, agree with each other.
  # - When the check runs as an action, it runs at that same revision.
  class RevisionCheck
    REPOSITORY = "marcortola/ci-deploy"
    REFERENCE = %r{#{Regexp.escape(REPOSITORY)}(?<path>/[A-Za-z0-9_./-]*)?@(?<ref>[^\s'"#]+)(?<rest>[^\n]*)}i
    SHA = /\A[0-9a-f]{40}\z/

    Reference = Struct.new(:file, :line, :ref, :comment, keyword_init: true)
    Result = Struct.new(:sha, :errors, :references, keyword_init: true) do
      def ok? = errors.empty?
    end

    # The ref the runner fetched an action at: it stores remote actions under
    # _actions/<owner>/<repo>/<ref>/. A local checkout (uses: ./...) has none.
    def self.ref_from_action_path(path)
      path.to_s[%r{/_actions/#{Regexp.escape(REPOSITORY)}/([^/]+)(?:/|\z)}i, 1].to_s
    end

    def initialize(component:, workflows: ".github/workflows", own_ref: nil)
      @component = File.expand_path(component)
      @workflows = File.expand_path(workflows, @component)
      @own_ref = own_ref.to_s
    end

    def call
      errors = []
      references = []
      return Result.new(sha: nil, errors: ["#{relative(@workflows)} does not exist"], references: []) unless Dir.exist?(@workflows)

      top_level = Dir.glob(File.join(@workflows, "*.{yml,yaml}")).sort
      top_level.each { |file| references.concat(scan(file)) }

      files = known_files
      return Result.new(sha: nil, errors: ["#{@component} is not a git checkout, so its files cannot be listed"], references: []) unless files

      (files - top_level).each do |file|
        scan(file).each do |reference|
          errors << "#{relative(file)}:#{reference.line} references #{REPOSITORY}; only top-level workflows in #{relative(@workflows)} may"
        end
      end

      if references.empty?
        errors << "no workflow in #{relative(@workflows)} references #{REPOSITORY}"
        return Result.new(sha: nil, errors: errors, references: references)
      end

      references.reject { |reference| reference.ref.match?(SHA) }.each do |reference|
        errors << "#{relative(reference.file)}:#{reference.line} pins #{REPOSITORY} to '#{reference.ref}', not a full commit SHA"
      end

      shas = references.map(&:ref).uniq
      if shas.size > 1
        listing = references.map { |reference| "  #{relative(reference.file)}:#{reference.line} @ #{reference.ref}" }.join("\n")
        errors << "#{REPOSITORY} is pinned to #{shas.size} different revisions:\n#{listing}"
      end

      comments = references.map(&:comment).compact.uniq
      if comments.size > 1
        errors << "the release comments on the #{REPOSITORY} references disagree: #{comments.join(', ')}"
      end

      sha = shas.size == 1 && shas.first.match?(SHA) ? shas.first : nil
      if sha && !@own_ref.empty? && @own_ref != sha
        errors << "this check runs at #{@own_ref}, but the workflows pin #{sha}; pin the check to the same revision"
      end

      Result.new(sha: sha, errors: errors, references: references)
    end

    private

    def scan(file)
      content = File.binread(file).force_encoding("UTF-8").scrub

      content.each_line.with_index(1).flat_map do |line, number|
        line.to_enum(:scan, REFERENCE).map do
          match = Regexp.last_match
          comment = match[:rest][/#\s*(\S+)/, 1]
          Reference.new(file: file, line: number, ref: match[:ref], comment: comment)
        end
      end
    end

    # Tracked files plus untracked ones that are not ignored, as absolute paths; nil outside git.
    def known_files
      output, _errors, status = Open3.capture3("git", "-C", @component, "ls-files", "-z", "--cached", "--others", "--exclude-standard")
      return nil unless status.success?

      output.split("\0").uniq.map { |path| File.join(@component, path) }.select { |path| File.file?(path) }.sort
    rescue SystemCallError
      nil
    end

    def relative(path)
      path.start_with?("#{@component}/") ? path.delete_prefix("#{@component}/") : path
    end
  end
end

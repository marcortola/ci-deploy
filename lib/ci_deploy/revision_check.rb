# frozen_string_literal: true

module CiDeploy
  # Checks that a component consumes this repository at exactly one revision.
  #
  # - Every reference lives in a top-level workflow (.github/workflows/*.yml or *.yaml). A local
  #   action under .github/workflows/shared/ (or anywhere else) that referenced this repository would
  #   be a second pin that Dependabot's workflow-directory entry never updates.
  # - Every reference is pinned to a full 40-character commit SHA, and all of them to the same one,
  #   so setup, deploy, operations, their helpers and the local launcher run the same code.
  # - Release comments on those references, when present, agree with each other.
  # - The vendored local launcher, when present, is identical to the one at that revision.
  # - When the check runs as an action, it runs at that same revision.
  class RevisionCheck
    REPOSITORY = "marcortola/ci-deploy"
    REFERENCE = %r{#{Regexp.escape(REPOSITORY)}(?<path>/[A-Za-z0-9_./-]*)?@(?<ref>[^\s'"#]+)(?<rest>[^\n]*)}
    SHA = /\A[0-9a-f]{40}\z/

    Reference = Struct.new(:file, :line, :ref, :comment, keyword_init: true)
    Result = Struct.new(:sha, :errors, :references, keyword_init: true) do
      def ok? = errors.empty?
    end

    # The ref the runner fetched an action at: it stores remote actions under
    # _actions/<owner>/<repo>/<ref>/. A local checkout (uses: ./...) has none.
    def self.ref_from_action_path(path)
      path.to_s[%r{/_actions/#{Regexp.escape(REPOSITORY)}/([^/]+)(?:/|\z)}, 1].to_s
    end

    def initialize(component:, workflows: ".github/workflows", launcher: nil, launcher_template: nil, own_ref: nil)
      @component = File.expand_path(component)
      @workflows = File.expand_path(workflows, @component)
      @github_dir = File.join(@component, ".github")
      @launcher = launcher.to_s.empty? ? nil : File.expand_path(launcher, @component)
      @launcher_template = launcher_template
      @own_ref = own_ref.to_s
    end

    def call
      errors = []
      references = []
      return Result.new(sha: nil, errors: ["#{relative(@workflows)} does not exist"], references: []) unless Dir.exist?(@workflows)

      top_level = Dir.glob(File.join(@workflows, "*.{yml,yaml}")).sort
      top_level.each { |file| references.concat(scan(file)) }

      others = Dir.glob(File.join(@github_dir, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }.sort - top_level
      others.each do |file|
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

      check_launcher(errors)
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

    def check_launcher(errors)
      return unless @launcher
      return errors << "the local launcher #{relative(@launcher)} does not exist" unless File.file?(@launcher)
      return unless @launcher_template

      unless File.binread(@launcher) == File.binread(@launcher_template)
        errors << "the local launcher #{relative(@launcher)} differs from the one at the pinned revision; copy launcher/ci-deploy-local from it"
      end
    end

    def relative(path)
      path.start_with?("#{@component}/") ? path.delete_prefix("#{@component}/") : path
    end
  end
end

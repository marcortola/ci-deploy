# Releasing

Consumers pin a full commit SHA with the release as a comment, so a release is a tag on a commit
of `main` whose checks passed.

1. Merge to `main` through a pull request whose CI passed: lint, unit suite, integration suite
   and the remote-consumption workflow, which runs the actions from GitHub by SHA.
2. Choose the version (SemVer): a new input or operation is a minor release; a changed default,
   a removed input, a Kamal minor or major upgrade or any change a consumer must act on is a
   major release; fixes are patch releases.
3. Tag the merge commit and push the tag:

   ```sh
   git switch main && git pull --ff-only
   git tag -a v1.2.0 -m "v1.2.0"
   git push origin v1.2.0
   ```

4. Create the GitHub release from the tag, listing changes and any action a consumer must take
   (proxy upgrade, behaviour change, launcher update).
5. Consumers move with Dependabot's grouped pull request (see [Dependabot](dependabot.md)) or by
   hand: replace every SHA and comment, copy `launcher/ci-deploy-local` from the new SHA, and run
   the revision check.

Never move or delete a published tag: consumers pin the SHA, and the comment must keep naming it.

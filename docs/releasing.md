# Releasing

Consumers pin a full commit SHA with the release as a comment, so a release is a tag on a commit
of `main` whose checks passed.

1. Merge to `main` through a pull request whose CI passed: lint, unit suite, integration suite
   and the remote-consumption workflow, which runs the actions from GitHub by SHA. When the pull
   request changes an action, `lib`, `bin` or the bundle, its last commit re-pins
   `.github/workflows/remote-consumer.yml` and `test/fixtures/revision-consumer` to the commit
   carrying that code: `script/check-remote-pin` fails CI until the pin's action code matches HEAD.
2. Choose the version (SemVer): a new input or operation is a minor release; a changed default,
   a removed input, a Kamal minor or major upgrade or any change a consumer must act on is a
   major release; fixes are patch releases.

   Kamal minor and major versions are upgraded by hand, never by Dependabot: a Kamal minor can
   raise the minimum kamal-proxy version (`Kamal::Configuration::Proxy::Run::MINIMUM_VERSION`),
   after which every deploy to a host with an older proxy fails until the
   [proxy procedure](proxy.md) runs there. Read that constant in the new Kamal before releasing,
   and when it changes, say so in the release notes as an action every consumer must take.
3. Tag the merge commit and push the tag:

   ```sh
   git switch main && git pull --ff-only
   git tag -a v1.2.0 -m "v1.2.0"
   git push origin v1.2.0
   ```

4. Create the GitHub release from the tag, listing changes and any action a consumer must take
   (proxy upgrade, behaviour change).
5. Consumers move with Dependabot's grouped pull request (see [Dependabot](dependabot.md)) or by
   hand: replace every SHA and comment, and run the revision check.

Never move or delete a published tag: consumers pin the SHA, and the comment must keep naming it.

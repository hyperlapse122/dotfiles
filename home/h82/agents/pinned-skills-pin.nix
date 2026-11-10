# Published skills installed unchanged. Each upstream names its flake input,
# the ref flake.nix pins it to (a tag, or the commit itself when upstream has
# no tag), and `expectedRev`, the commit that ref is expected to name:
# tests/pinned-skills.nix compares it with flake.lock, so a moved tag fails a
# check instead of arriving as a lock diff.
#
# A skill is installed under its SKILL.md frontmatter name, copied from `path`
# in the input. `files` limits the copy to the entries upstream ships as the
# skill, for a repository whose root holds other files too; without it the
# whole directory is copied. Nothing is edited. `license` is the license file
# copied beside the skill, relative to the input root, or null when upstream
# has none and `licenseSource` says where its license is declared.
{
  upstreams = [
    {
      input = "anthropic-skills";
      ref = "dbd4588f9e1033efb41dad4bef2f7947c8993d44";
      expectedRev = "dbd4588f9e1033efb41dad4bef2f7947c8993d44";
      skills = [
        {
          name = "frontend-design";
          path = "skills/frontend-design";
          license = "skills/frontend-design/LICENSE.txt";
        }
      ];
    }
    {
      input = "vercel-agent-skills";
      ref = "agent-skills-1a2c79d4e6c4a2283dc2c614b6538cbe1ed5ca62";
      expectedRev = "1a2c79d4e6c4a2283dc2c614b6538cbe1ed5ca62";
      skills = map (skill: skill // { license = null; }) [
        {
          name = "web-design-guidelines";
          path = "skills/web-design-guidelines";
        }
        {
          name = "vercel-react-best-practices";
          path = "skills/react-best-practices";
        }
        {
          name = "vercel-composition-patterns";
          path = "skills/composition-patterns";
        }
        {
          name = "vercel-react-native-skills";
          path = "skills/react-native-skills";
        }
      ];
      licenseSource = "MIT, declared in the License section of README.md; the repository has no license file";
    }
    {
      input = "expo-skills";
      ref = "8a0dc4fa57ae345923c357e1451cbcd8b6f2a7db";
      expectedRev = "8a0dc4fa57ae345923c357e1451cbcd8b6f2a7db";
      skills =
        map
          (name: {
            inherit name;
            path = "plugins/expo/skills/${name}";
            license = "LICENSE";
          })
          [
            "expo-native-ui"
            "expo-upgrade"
            # expo-native-ui tells agents to load these four.
            "expo-ui"
            "expo-animation"
            "expo-router"
            "expo-data-fetching"
          ];
    }
    {
      input = "playwright-best-practices-skill";
      ref = "283d5cbc5d11aac1abda058b16ad22c317d54dc0";
      expectedRev = "283d5cbc5d11aac1abda058b16ad22c317d54dc0";
      skills = [
        {
          name = "playwright-best-practices";
          path = "playwright-best-practices";
          license = "LICENSE.md";
        }
      ];
    }
    {
      input = "ux-writing-skill";
      ref = "v1.5.0";
      expectedRev = "ee8206f22451fdbac8037b1ffb86c849d3cb8c61";
      skills = [
        {
          name = "ux-writing";
          path = ".";
          # The set build-skill.sh packages as the skill.
          files = [
            "SKILL.md"
            "docs"
            "examples"
            "references"
            "templates"
          ];
          license = "LICENSE";
        }
      ];
    }
    {
      input = "kergoth-dotfiles";
      ref = "7f61f919d27e3016b64c37ce09b7006199ad7878";
      expectedRev = "7f61f919d27e3016b64c37ce09b7006199ad7878";
      skills = [
        {
          name = "cli-design";
          path = "home/dot_agents/skills/cli-design";
          license = "LICENSE.md";
        }
      ];
    }
  ];

  # impeccable contributes only its lens references, from the tree its build
  # renders for plugins, inside the local design-lenses skill. Its SKILL.md,
  # scripts, agents, and workflow references (init, document, live, hooks,
  # doctor, routing, shape, new-work, and the like) are not installed.
  impeccable = {
    input = "impeccable";
    ref = "skill-v4.8.0";
    expectedRev = "414603bf14c7a344edb466bb1f85690c77ce8b7d";
    referencePath = "plugin/skills/impeccable/reference";
    references = [
      "adapt.md"
      "adapt.native.md"
      "android.md"
      "animate.md"
      "audit.md"
      "audit.native.md"
      "bolder.md"
      "clarify.md"
      "colorize.md"
      "craft-floor.md"
      "delight.md"
      "distill.md"
      "harden.md"
      "ios.md"
      "layout.md"
      "mode-operate.md"
      "mode-persuade.md"
      "mode-read.md"
      "onboard.md"
      "operate.md"
      "optimize.md"
      "polish.md"
      "quieter.md"
      "typeset.md"
    ];
    license = "LICENSE";
    notice = "NOTICE.md";
  };
}

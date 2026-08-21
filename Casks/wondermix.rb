cask "wondermix" do
  version "1.0.0"
  sha256 "8011e44a8b9ddd8b3e0c08872ef25a94a757b21f6e939e4ac309ad5d544441a0"

  url "https://github.com/IgorYanko/WonderMix/releases/download/v#{version}/WonderMix-macOS.zip"
  name "WonderMix"
  desc "Per-app volume and output device mixer for macOS"
  homepage "https://github.com/IgorYanko/WonderMix"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sequoia"

  app "WonderMix.app"

  zap trash: [
    "~/Library/Preferences/com.wondermix.app.plist",
  ]
end

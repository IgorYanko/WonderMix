cask "wondermix" do
  version "1.0.0"
  sha256 "e18da062e086dd990d9a18d8fa3a344607230c07c9f90ac0b5e68f2961a44679"

  url "https://github.com/IgorYanko/WonderMix/releases/download/v#{version}/WonderMix-macOS.zip"
  name "WonderMix"
  desc "Per-app volume and output device mixer for macOS"
  homepage "https://github.com/IgorYanko/WonderMix"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sequoia

  app "WonderMix.app"

  zap trash: [
    "~/Library/Preferences/com.wondermix.app.plist",
  ]
end

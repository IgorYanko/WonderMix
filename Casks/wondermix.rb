cask "wondermix" do
  version "1.0.0"
  sha256 "a79c647c4e7274f6cdedbe1607227c963c437dbad72411e7c31a7547c132da72"

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

  postflight do
    system_command "xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/WonderMix.app"],
                   sudo: false
  end

  caveats <<~EOS
    Se o macOS bloquear a abertura por ser um app sem assinatura paga da Apple:
      xattr -d com.apple.quarantine /Applications/WonderMix.app
    Ou instale com:
      brew install --cask --no-quarantine wondermix
  EOS

  zap trash: "~/Library/Preferences/com.wondermix.app.plist"
end

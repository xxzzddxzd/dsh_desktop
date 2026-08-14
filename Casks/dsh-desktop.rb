cask "dsh-desktop" do
  version "0.1.0"
  sha256 "b362b45de70e966345203329b451ce779f84795cd0226a6499c6183cc312d805"

  url "https://github.com/xxzzddxzd/dsh_desktop/releases/download/v#{version}/dsh-desktop.zip"
  name "DSH Desktop"
  desc "DeepSeek Harness menu bar companion"
  homepage "https://github.com/xxzzddxzd/dsh_desktop"

  depends_on macos: ">= :ventura"
  depends_on arch: :arm64

  app "DSH Desktop.app"

  caveats "应用为 ad-hoc 签名且未公证：若首次启动被 Gatekeeper 拦截，请右键 → 打开。"
end

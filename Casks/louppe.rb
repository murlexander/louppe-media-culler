cask "louppe" do
  version "1.14.0"
  sha256 "f190266b7c805f7664fd7d0e8c26a872f8cba83b13ce51e0820436670c7770ad"

  url "https://github.com/murlexander/louppe-media-culler/releases/download/v#{version}/Louppe.zip",
      verified: "github.com/murlexander/louppe-media-culler/"
  name "Louppe"
  desc "Photo viewer and culler for local folders"
  homepage "https://louppe.eu/"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Louppe.app"
end

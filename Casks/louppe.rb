cask "louppe" do
  version "1.13.1"
  sha256 "8584fa839e277cc2668ea61409485dab7e9353b542b3dc7575d450e7ddce75b7"

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

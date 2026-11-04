cask "louppe" do
  version "1.13.0"
  sha256 "8386a60e6cb9f50b3c33dc4d340a1fbc4374c65b8a5b7ba2c381f3f9c7d726d0"

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

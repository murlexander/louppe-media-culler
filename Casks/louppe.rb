cask "louppe" do
  version "1.13.2"
  sha256 "8e9d55ce9cd4ded6733357ea6db15e1e51933451fd1eda7c311355d19bccff40"

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

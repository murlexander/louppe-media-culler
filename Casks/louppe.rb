cask "louppe" do
  version "1.11.0"
  sha256 "6b232a6be28245435068c160a71eba6d4539d371e44fceeed67a5f8f7a4af547"

  url "https://github.com/murlexander/louppe-media-culler/releases/download/v#{version}/Louppe.zip",
      verified: "github.com/murlexander/louppe-media-culler/"
  name "Louppe"
  desc "Keyboard-first media culler"
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

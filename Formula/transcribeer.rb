class Transcribeer < Formula
  desc "Local-first meeting transcription and summarization for macOS"
  homepage "https://github.com/moshebe/transcribeer"
  url "https://github.com/moshebe/transcribeer/archive/refs/tags/v0.1.1.tar.gz"
  sha256 "a92258f5eb1dec3cf3fe2588f7d41378d1bdf69090065556f94c6b45006c72c0"
  license "MIT"

  depends_on "ffmpeg"
  depends_on macos: :ventura
  depends_on "python@3.11"

  def install
    # Install script handles venv, package, and binary setup
    ENV["TRANSCRIBEER_NONINTERACTIVE"] = "1"
    system "./install.sh"
  end

  def caveats
    <<~EOS
      Transcribeer has been installed.

      First run:
        transcribeer-gui       # launch the menubar app
        transcribeer --help    # CLI usage

      To configure your LLM backend (Ollama/OpenAI/Anthropic) and diarization:
        ~/.transcribeer/config.toml

      Note: The first transcription will download the Whisper model (~1.5 GB).
      This happens automatically on first use.

      Recording consent: You are responsible for complying with all applicable
      laws regarding recording of conversations in your jurisdiction.
    EOS
  end

  test do
    system "#{bin}/transcribeer", "--help"
  end
end

class NginxOptimizer < Formula
  desc "Comprehensive NGINX optimization tool for WordPress"
  homepage "https://github.com/MarcinDudekDev/nginx-optimizer"
  head "https://github.com/MarcinDudekDev/nginx-optimizer.git", branch: "main"
  license "MIT"

  depends_on "bash"
  depends_on "jq"
  depends_on "curl"
  depends_on "rsync"

  def install
    libexec.install "nginx-optimizer.sh"
    libexec.install "nginx-optimizer-lib"
    libexec.install "nginx-optimizer-templates"

    (bin/"nginx-optimizer").write <<~EOS
      #!/bin/bash
      SCRIPT_DIR="#{libexec}"
      export SCRIPT_DIR
      exec "#{HOMEBREW_PREFIX}/bin/bash" "#{libexec}/nginx-optimizer.sh" "$@"
    EOS
  end

  test do
    output = shell_output("#{bin}/nginx-optimizer --version 2>&1")
    assert_match "nginx-optimizer", output
  end

  def caveats
    <<~EOS
      nginx-optimizer has been installed!

      Configuration and data are stored in:
        ~/.nginx-optimizer/

      Integration with wp-test:
        If you have wp-test installed, nginx-optimizer will detect it automatically.

      Get started:
        nginx-optimizer help
        nginx-optimizer analyze [site]
        nginx-optimizer optimize [site]

      For more information, visit:
        https://github.com/MarcinDudekDev/nginx-optimizer
    EOS
  end
end

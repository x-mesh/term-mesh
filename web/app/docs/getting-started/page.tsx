import type { Metadata } from "next";
import { CodeBlock } from "../../components/code-block";
import { Callout } from "../../components/callout";
import { DownloadButton } from "../../components/download-button";

export const metadata: Metadata = {
  title: "Getting Started",
  description:
    "Install term-mesh, the native macOS terminal for AI coding agents. Homebrew, DMG download, CLI setup, and auto-updates via Sparkle.",
};

export default function GettingStartedPage() {
  return (
    <>
      <h1>Getting Started</h1>
      <p>
        term-mesh is a lightweight, native macOS terminal built on Ghostty for
        managing multiple AI coding agents. It features vertical tabs, a
        notification panel, and a socket-based control API.
      </p>

      <h2>Install</h2>

      <h3>DMG (recommended)</h3>
      <div className="my-4">
        <DownloadButton />
      </div>
      <p>
        Open the <code>.dmg</code> and drag term-mesh to your Applications folder.
        term-mesh auto-updates via Sparkle, so you only need to download once.
      </p>

      <h3>Homebrew</h3>
      <CodeBlock lang="bash">{`brew tap JINWOO-J/term-mesh
brew install --cask term-mesh`}</CodeBlock>
      <p>To update later:</p>
      <CodeBlock lang="bash">{`brew upgrade --cask term-mesh`}</CodeBlock>

      <Callout>
        On first launch, macOS may ask you to confirm opening an app from an
        identified developer. Click <strong>Open</strong> to proceed.
      </Callout>

      <h2>Verify installation</h2>
      <p>Open term-mesh and you should see:</p>
      <ul>
        <li>A terminal window with a vertical tab sidebar on the left</li>
        <li>One initial workspace already open</li>
        <li>The Ghostty-powered terminal ready for input</li>
      </ul>

      <h2>CLI setup</h2>
      <p>
        term-mesh includes a command-line tool for automation. Inside term-mesh terminals
        it works automatically. To use the CLI from outside term-mesh, create a
        symlink:
      </p>
      <CodeBlock lang="bash">{`sudo ln -sf "/Applications/term-mesh.app/Contents/Resources/bin/term-mesh" /usr/local/bin/term-mesh`}</CodeBlock>
      <p>Then you can run commands like:</p>
      <CodeBlock lang="bash">{`term-mesh list-workspaces
term-mesh notify --title "Build Complete" --body "Your build finished"`}</CodeBlock>

      <h2>Auto-updates</h2>
      <p>
        term-mesh checks for updates automatically via Sparkle. When an update is
        available you&apos;ll see an update pill in the titlebar. You can also
        check manually via <strong>term-mesh → Check for Updates</strong> in the menu
        bar.
      </p>

      <h2>Requirements</h2>
      <ul>
        <li>macOS 14.0 or later</li>
        <li>Apple Silicon or Intel Mac</li>
      </ul>
    </>
  );
}

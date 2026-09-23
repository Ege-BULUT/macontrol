import Foundation

/// The folder lists behind `ProtectedPaths`. Paths are canonical spellings (what `F_GETPATH`
/// returns), so `/var` and `/tmp` appear only because the symlinks themselves must never go.
///
/// `systemRoots` and `homeRoots` start from Homebrew's `SYSTEM_DIRS` and `UNDELETABLE_PATHS`
/// (Library/Homebrew/cask/macos.rb @ 3f12c3e, BSD-2-Clause); the entries under `/System` and `/usr`
/// are covered by `systemNeverTouch` and were dropped. The cloud provider state in `homeNeverTouch`
/// comes from PureMac's ProviderPaths.swift (@ bef6083, MIT). Both license texts are at the end of
/// this file. Homebrew and PureMac match these paths exactly; macontrol uses them for containment (F-0024).
enum ProtectedLocations {
    /// Never trashed, nor any folder containing one. What is inside them may be.
    static let systemRoots = paths("""
        /
        /Applications
        /Applications/Utilities
        /Incompatible Software
        /Library
        /Library/Application Support
        /Library/Audio
        /Library/Caches
        /Library/ColorPickers
        /Library/ColorSync
        /Library/Components
        /Library/Compositions
        /Library/Contextual Menu Items
        /Library/CoreMediaIO
        /Library/Desktop Pictures
        /Library/Developer
        /Library/Dictionaries
        /Library/DirectoryServices
        /Library/Documentation
        /Library/Extensions
        /Library/Filesystems
        /Library/Fonts
        /Library/Frameworks
        /Library/Graphics
        /Library/Image Capture
        /Library/Input Methods
        /Library/Internet Plug-Ins
        /Library/Java
        /Library/Java/Extensions
        /Library/Java/JavaVirtualMachines
        /Library/Keyboard Layouts
        /Library/Keychains
        /Library/LaunchAgents
        /Library/LaunchDaemons
        /Library/Logs
        /Library/Messages
        /Library/Modem Scripts
        /Library/OpenDirectory
        /Library/PDF Services
        /Library/Perl
        /Library/PreferencePanes
        /Library/Preferences
        /Library/Printers
        /Library/PrivilegedHelperTools
        /Library/Python
        /Library/QuickLook
        /Library/QuickTime
        /Library/Receipts
        /Library/Ruby
        /Library/Sandbox
        /Library/Screen Savers
        /Library/ScriptingAdditions
        /Library/Scripts
        /Library/Security
        /Library/Speech
        /Library/Spelling
        /Library/Spotlight
        /Library/StartupItems
        /Library/SystemProfiler
        /Library/Updates
        /Library/User Pictures
        /Library/Video
        /Library/WebServer
        /Library/Widgets
        /Library/iTunes
        /Network
        /User Information
        /Users
        /Volumes
        /boot
        /cores
        /dev
        /etc
        /etc/X11
        /etc/opt
        /etc/sgml
        /etc/xml
        /home
        /libexec
        /lost+found
        /media
        /mnt
        /net
        /opt
        /private
        /private/etc
        /private/tftpboot
        /private/tmp
        /private/var
        /proc
        /root
        /srv
        /tmp
        /usr/local
        /usr/local/Cellar
        /usr/local/Frameworks
        /usr/local/Library
        /usr/local/bin
        /usr/local/etc
        /usr/local/include
        /usr/local/lib
        /usr/local/libexec
        /usr/local/opt
        /usr/local/share
        /usr/local/share/man
        /usr/local/var
        /usr/local/var/lib
        /usr/local/var/lock
        /usr/local/var/run
        /var
        /var/cache
        /var/lib
        /var/lock
        /var/log
        /var/mail
        /var/run
        /var/spool
        /var/spool/mail
        /var/tmp
        /AppleInternal
        /opt/homebrew
        /private/var/db
        /private/var/folders
        """)

    /// Relative to home; home itself is a root too.
    static let homeRoots = paths("""
        Applications
        Desktop
        Documents
        Downloads
        Mail
        Movies
        Music
        Music/iTunes
        Music/iTunes/iTunes Music
        Music/iTunes/Album Artwork
        News
        Pictures
        Pictures/Desktops
        Pictures/Photo Booth
        Pictures/iChat Icons
        Pictures/iPhoto Library
        Public
        Sites
        Library
        Library/Accessibility
        Library/Accounts
        Library/Address Book Plug-Ins
        Library/Application Scripts
        Library/Application Support
        Library/Application Support/Apple
        Library/Application Support/com.apple.AssistiveControl
        Library/Application Support/com.apple.QuickLook
        Library/Application Support/com.apple.TCC
        Library/Assistants
        Library/Audio
        Library/Automator
        Library/Autosave Information
        Library/Caches
        Library/Calendars
        Library/ColorPickers
        Library/ColorSync
        Library/Colors
        Library/Components
        Library/Compositions
        Library/Containers
        Library/Contextual Menu Items
        Library/Cookies
        Library/DTDs
        Library/Desktop Pictures
        Library/Developer
        Library/Dictionaries
        Library/DirectoryServices
        Library/Displays
        Library/Documentation
        Library/Extensions
        Library/Favorites
        Library/FileSync
        Library/Filesystems
        Library/Filters
        Library/FontCollections
        Library/Fonts
        Library/Frameworks
        Library/GameKit
        Library/Graphics
        Library/Group Containers
        Library/Icons
        Library/IdentityServices
        Library/Image Capture
        Library/Images
        Library/Input Methods
        Library/Internet Plug-Ins
        Library/InternetAccounts
        Library/iTunes
        Library/KeyBindings
        Library/Keyboard Layouts
        Library/Keychains
        Library/LaunchAgents
        Library/LaunchDaemons
        Library/LocationBundles
        Library/LoginPlugins
        Library/Logs
        Library/Mail
        Library/Mail Downloads
        Library/Messages
        Library/Metadata
        Library/Mobile Documents
        Library/MonitorPanels
        Library/OpenDirectory
        Library/PDF Services
        Library/PhonePlugins
        Library/Phones
        Library/PreferencePanes
        Library/Preferences
        Library/Printers
        Library/PrivateFrameworks
        Library/PubSub
        Library/QuickLook
        Library/QuickTime
        Library/Receipts
        Library/Recent Servers
        Library/Recents
        Library/Safari
        Library/Saved Application State
        Library/Screen Savers
        Library/ScreenReader
        Library/ScriptingAdditions
        Library/ScriptingDefinitions
        Library/Scripts
        Library/Security
        Library/Services
        Library/Sounds
        Library/Speech
        Library/Spelling
        Library/Spotlight
        Library/StartupItems
        Library/StickiesDatabase
        Library/Sync Services
        Library/SyncServices
        Library/SyncedPreferences
        Library/TextEncodings
        Library/User Pictures
        Library/Video
        Library/Voices
        Library/WebKit
        Library/WidgetResources
        Library/Widgets
        Library/Workflows
        Library/CloudStorage
        Library/HTTPStorages
        Library/Daemon Containers
        """)

    /// Nothing at or inside these is ever trashed. `/usr/local` is carved out of `/usr` in `ProtectedPaths`.
    static let systemNeverTouch = [
        "/System", "/usr", "/bin", "/sbin", "/dev", "/private/var/vm",
        "/.Spotlight-V100", "/.fseventsd", "/.DocumentRevisions-V100", "/.vol",
        "/Library/Keychains", "/Library/Application Support/com.apple.TCC",
    ]

    static let homeNeverTouch = [
        ".Trash", "Library/Keychains", ".ssh", ".gnupg", "Library/Mail", "Library/Containers/com.apple.mail",
        "Library/Messages", "Library/Application Support/com.apple.TCC",
        // Cloud provider state: deleting under it corrupts sync (PureMac #142).
        "Library/Application Support/FileProvider", "Library/Application Support/CloudDocs",
        "Library/Daemon Containers", "Library/Caches/CloudKit", "Library/Caches/com.apple.bird",
        "Library/Caches/com.apple.cloudkit", "Library/Caches/com.apple.cloudd",
        "Library/Caches/com.apple.FileProvider",
    ]

    /// A bundle with one of these extensions is never trashed, nor anything inside it.
    static let neverTouchExtensions = ["photoslibrary", "photolibrary", "migratedphotolibrary"]

    /// Folders with these names are never trashed, nor anything inside them: every volume's Trash.
    static let neverTouchNames = [".trashes"]

    /// Deleting here deletes on every device, so it needs the user's explicit confirmation.
    static let homeCloud = ["Library/Mobile Documents", "Library/CloudStorage"]

    private static func paths(_ list: String) -> [String] {
        list.split(separator: "\n").map { String($0) }
    }
}

/*
 Homebrew (https://github.com/Homebrew/brew), BSD 2-Clause License

 Copyright (c) 2009-present, Homebrew contributors
 All rights reserved.

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:

 * Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

 * Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
 FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

 PureMac (https://github.com/momenbasel/PureMac), MIT License

 Copyright (c) 2026 PureMac Contributors

 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 SOFTWARE.
*/

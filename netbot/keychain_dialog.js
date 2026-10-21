// NetBot: ask for the router password in a native macOS dialog and save it straight into the
// login Keychain, all inside this one osascript (JXA) process. The password is never printed,
// never passed as a command-line argument, never written to a file or log, and never returned.
// Usage: osascript -l JavaScript keychain_dialog.js <service> <account> <router-address> [<window title>]
// The window title is passed in by install.sh (APP_NAME, from netbot/ui_text.py via strings/messages.sh).
// Prints only a status word: OK | SKIPPED | ERROR <code>
ObjC.import('Foundation');
ObjC.import('Security');

function run(argv) {
  const service = argv[0], account = argv[1], host = argv[2] || 'your router', title = argv[3] || 'NetBot';
  const app = Application.currentApplication();
  app.includeStandardAdditions = true;
  let r;
  try {
    r = app.displayDialog(
      'The router add-on can read more router stats with your router\'s admin password (router at ' + host + ').\n\n' +
      'It is saved only in this Mac\'s Keychain.',
      { withTitle: title, defaultAnswer: '', hiddenAnswer: true,
        buttons: ['Skip', 'Save'], defaultButton: 'Save', withIcon: 'note' });
  } catch (e) {
    return 'SKIPPED';   // Cancel / Esc
  }
  if (r.buttonReturned !== 'Save' || r.textReturned.length === 0) return 'SKIPPED';

  const q = $.NSMutableDictionary.alloc.init;
  q.setObjectForKey($.kSecClassGenericPassword, $.kSecClass);
  q.setObjectForKey($(service), $.kSecAttrService);
  q.setObjectForKey($(account), $.kSecAttrAccount);
  $.SecItemDelete(q);  // replace any older NetBot item (like security -U)
  q.setObjectForKey($('NetBot router password'), $.kSecAttrLabel);
  q.setObjectForKey($(r.textReturned).dataUsingEncoding($.NSUTF8StringEncoding), $.kSecValueData);
  r = null;
  const status = $.SecItemAdd(q, null);
  return status === 0 ? 'OK' : 'ERROR ' + status;
}

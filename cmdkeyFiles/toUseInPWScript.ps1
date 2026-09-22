#
Add-Type @'
using System;
using System.Runtime.InteropServices;

public class WinCred {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CREDENTIAL {
        public uint Flags;
        public uint Type;
        public IntPtr TargetName;
        public IntPtr Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public IntPtr TargetAlias;
        public IntPtr UserName;
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CredRead(
        string target,
        uint type,
        uint flags,
        out IntPtr credential);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern void CredFree(IntPtr credential);
}
'@

$target = "testor"

$ptr = [IntPtr]::Zero
$ok = [WinCred]::CredRead($target, 1, 0, [ref]$ptr)

if (-not $ok) {
    $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    throw "CredRead failed. Win32 error: $errorCode"
}

try {
    $cred = [Runtime.InteropServices.Marshal]::PtrToStructure(
        $ptr,
        [type][WinCred+CREDENTIAL]
    )

    $username = [Runtime.InteropServices.Marshal]::PtrToStringUni(
        $cred.UserName
    )

    $secret = [Runtime.InteropServices.Marshal]::PtrToStringUni(
        $cred.CredentialBlob
    )

    $username
    $secret
}
finally {
    [WinCred]::CredFree($ptr)
}
<#
Store the credential like
cmdkey /generic:<target-name> /user:<username> /pass:<password>

eg:-
Add new credential
cmdkey /generic:test /user:tester /pass:newGuy234

Update the existing credential
cmdkey /generic:test /user:tester /pass:oldGuy234
#>

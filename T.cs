using System; using System.IO; using System.Security.Cryptography;
public static class T {
    public static void Main(string[] a) {
        var key = File.ReadAllText(a[0]); var sig = Convert.FromBase64String(File.ReadAllText(a[1]).Trim());
        string hash; using (var sha = SHA256.Create()) hash = BitConverter.ToString(sha.ComputeHash(File.ReadAllBytes(a[2]))).Replace("-", "").ToLowerInvariant();
        using (var rsa = new RSACryptoServiceProvider()) {
            rsa.FromXmlString(key);
            Func<string, string, string, bool> ok = (id, v, h) => rsa.VerifyHash(Manager.SignedMessageHash(id, v, h), CryptoConfig.MapNameToOID("SHA256"), sig);
            Console.WriteLine("firma giusta: " + ok("multitool", "2026.11.20.1", hash));
            Console.WriteLine("altro programma: " + ok("remostation", "2026.11.20.1", hash));
            Console.WriteLine("versione rietichettata: " + ok("multitool", "2099.1.1", hash));
            Console.WriteLine("file diverso: " + ok("multitool", "2026.11.20.1", hash.Replace(hash[0], hash[0] == 'a' ? 'b' : 'a')));
        }
    }
}

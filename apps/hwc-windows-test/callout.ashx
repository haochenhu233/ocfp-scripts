<%@ WebHandler Language="C#" Class="Callout" %>
using System; using System.Web; using System.Net; using System.IO;

// Container-to-container (c2c) driver. Makes a plaintext HTTP call to another app's
// internal address, e.g. target=win-bin.apps.internal:8080 path=/whoami
// c2c goes over the overlay directly to the app port, so it never traverses the
// route-integrity proxy: this should behave identically before and after the upgrade.
public class Callout : IHttpHandler {
  public void ProcessRequest(HttpContext c) {
    string target = c.Request.QueryString["target"];              // host:port
    string path   = c.Request.QueryString["path"] ?? "/whoami";
    string url    = "http://" + target + path;
    c.Response.ContentType = "application/json";
    try {
      var req = (HttpWebRequest)WebRequest.Create(url); req.Timeout = 10000;
      using (var resp = (HttpWebResponse)req.GetResponse())
      using (var sr = new StreamReader(resp.GetResponseStream())) {
        c.Response.Write("{\"ok\":true,\"url\":\"" + url + "\",\"status\":" + (int)resp.StatusCode + ",\"body\":" + J(sr.ReadToEnd()) + "}");
      }
    } catch (Exception e) {
      c.Response.Write("{\"ok\":false,\"url\":\"" + url + "\",\"error\":" + J(e.Message) + "}");
    }
  }
  static string J(string s) { return "\"" + (s ?? "").Replace("\\","\\\\").Replace("\"","\\\"").Replace("\n"," ").Replace("\r"," ") + "\""; }
  public bool IsReusable { get { return true; } }
}

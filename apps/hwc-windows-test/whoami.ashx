<%@ WebHandler Language="C#" Class="WhoAmI" %>
using System; using System.Web; using System.Text;

// Reports what the app actually sees at the socket + HTTP layer.
// Pre-upgrade  (52.0.0): remote_addr = gorouter/cell IP.
// Post-upgrade (56.4.0): remote_addr = 127.0.0.1 (envoy-nginx re-originates the connection);
//                        x_forwarded_for is unchanged (still the real client).
public class WhoAmI : IHttpHandler {
  public void ProcessRequest(HttpContext c) {
    var r = c.Request; var s = new StringBuilder();
    Action<string,string> f = (k,v) => s.AppendFormat("\"{0}\":\"{1}\",", k, (v ?? "").Replace("\"","'"));
    s.Append("{");
    f("remote_addr",             r.ServerVariables["REMOTE_ADDR"]);
    f("remote_port",             r.ServerVariables["REMOTE_PORT"]);
    f("local_addr",              r.ServerVariables["LOCAL_ADDR"]);
    f("x_forwarded_for",         r.Headers["X-Forwarded-For"]);
    f("x_forwarded_proto",       r.Headers["X-Forwarded-Proto"]);
    f("x_forwarded_client_cert", r.Headers["X-Forwarded-Client-Cert"]);
    f("host",                    r.Headers["Host"]);
    f("cf_instance_index",       Environment.GetEnvironmentVariable("CF_INSTANCE_INDEX"));
    f("cf_instance_ip",          Environment.GetEnvironmentVariable("CF_INSTANCE_IP"));
    f("cf_instance_internal_ip", Environment.GetEnvironmentVariable("CF_INSTANCE_INTERNAL_IP"));
    f("cf_instance_addr",        Environment.GetEnvironmentVariable("CF_INSTANCE_ADDR"));
    f("cf_instance_port",        Environment.GetEnvironmentVariable("CF_INSTANCE_PORT"));
    f("cf_instance_ports",       Environment.GetEnvironmentVariable("CF_INSTANCE_PORTS"));
    s.AppendFormat("\"port\":\"{0}\"}}", Environment.GetEnvironmentVariable("PORT"));
    c.Response.ContentType = "application/json";
    c.Response.Write(s.ToString());
  }
  public bool IsReusable { get { return true; } }
}

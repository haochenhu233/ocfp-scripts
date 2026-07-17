<%@ WebHandler Language="C#" Class="Health" %>
using System.Web;
public class Health : IHttpHandler {
  public void ProcessRequest(HttpContext c) { c.Response.ContentType = "text/plain"; c.Response.Write("ok"); }
  public bool IsReusable { get { return true; } }
}

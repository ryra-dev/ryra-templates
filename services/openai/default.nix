{
  meta = {
    title = "OpenAI";
    summary = "Use your organization's OpenAI API account";
    category = "tools";
    url = "https://platform.openai.com";
    auth.openai = {
      label = "OpenAI";
      why = "Use your organization's OpenAI project from this machine.";
      organization_owned = true;
      connect = {
        kind = "token";
        page = "https://platform.openai.com/api-keys";
        scopes = "Create a key in the OpenAI project you want to use.";
        fields = [ "api_key" ];
      };
      environment.OPENAI_API_KEY = "api_key";
    };
  };
}

{ ... }: {
  environment.etc."shared-content".text = builtins.readFile ./content.txt;
}

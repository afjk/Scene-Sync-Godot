using Godot;

public partial class DotNetAndroidSmoke : Node
{
    public override void _Ready()
    {
        GD.Print($".NET smoke node initialized on {OS.GetName()}.");
    }
}

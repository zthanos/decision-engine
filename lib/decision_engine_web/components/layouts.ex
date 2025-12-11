# lib/decision_engine_web/components/layouts.ex
defmodule DecisionEngineWeb.Layouts do
  use DecisionEngineWeb, :html

  embed_templates "layouts/*"
end

defmodule DecisionEngineWeb.ErrorHTML do
  use DecisionEngineWeb, :html

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end

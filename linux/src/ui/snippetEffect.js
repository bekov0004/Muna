import Clutter from 'gi://Clutter';
import Cogl from 'gi://Cogl';
import GObject from 'gi://GObject';
import Shell from 'gi://Shell';

/**
 * Makes an effect class that runs a piece of GLSL over an actor's picture (`code` runs after the
 * default fragment code, so it can change cogl_color_out). GNOME 50 has Shell.GLSLEffect for this;
 * GNOME 51 dropped it, and there Clutter.ShaderEffect takes the GLSL as a Cogl snippet instead.
 *
 * The GLSL is built once per class, not per instance: whatever differs between instances goes in
 * uniforms (declared in `declarations`), set with effect.setUniform(name, [values]).
 */
export function snippetEffect(gtypeName, declarations, code) {
    if (Shell.GLSLEffect) {
        return GObject.registerClass({GTypeName: gtypeName}, class extends Shell.GLSLEffect {
            vfunc_build_pipeline() {
                this.add_glsl_snippet(Cogl.SnippetHook.FRAGMENT, declarations, code, false);
            }

            setUniform(name, values) {
                this.set_uniform_float(this.get_uniform_location(name), values.length, values);
            }
        });
    }
    return GObject.registerClass({GTypeName: gtypeName}, class extends Clutter.ShaderEffect {
        vfunc_get_static_snippet() {
            return Cogl.Snippet.new(Cogl.SnippetHook.FRAGMENT, declarations, code);
        }

        setUniform(name, values) {
            this.set_uniform_float(name, values.length, values);
        }
    });
}

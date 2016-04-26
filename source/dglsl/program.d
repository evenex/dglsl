
module dglsl.program;

import std.string;

import derelict.opengl3.gl3;
import gl3n.linalg : Vector, Matrix;

import dglsl.gspl;
import dglsl.shader;


class Program(T...) {
    private GLuint _programid;
    @property auto id() const { return _programid; }

    mixin(shader_uniform!T);

    this(T shaders) {
        _programid = glCreateProgram();

        foreach (s; shaders) {
            glAttachShader(_programid, s.id);
        }

        glLinkProgram(_programid);

        GLint linked;
        glGetProgramiv(_programid, GL_LINK_STATUS, &linked);

        if (linked == GL_FALSE) {
            throw new Exception(infoLog(this));
        }

        setUniformLocations();
    }
}

/*
	exposes named vertex attribute bindings, like Program exposes uniform bindings.
	it would be better if it inhereted from Program, or was absorbed into Program
*/
template AttribProgram(Shaders...)
{
	import std.range;
	import std.meta;
	import std.traits;
	import std.format;

	class AttribProgram : Program!Shaders
	{
		GLuint vao;

		void use()
		{
			glUseProgram(this.id);
			glBindVertexArray(this.vao);
		}

		mixin(attribSetters.only.join("\n"));

		this(Shaders shaders)
		{
			super(shaders);

			glGenVertexArrays(1, &vao);
			glBindVertexArray(vao);
		}
		~this()
		{
			glDeleteVertexArrays(1, &vao);
		}
	}

	alias attribSetters = staticMap!(declAttribSetter, VertexAttribs);

	template declAttribSetter(VertexAttrib)
	{
		alias In = VertexAttrib;

		enum declAttribSetter = format(q{
				void %s(GLuint id)
				{
					use;
					glEnableVertexAttribArray(%s);
					glBindBuffer(GL_ARRAY_BUFFER, id);
					glVertexAttribPointer(%s, %s, %s, false, 0, null);
				}
			},
			In.name,
			In.location, 
			In.location, glElementSize!(In.Type), glElementType!(In.Type),
		);
	}

	alias VertexAttribs = staticMap!(
		VertexAttrib,
		Filter!(isVertexAttrib,
			__traits(derivedMembers, VertexShader)
		)
	);

	struct VertexAttrib(string attribName)
	{
		enum name = attribName;
		alias Type = typeof(__traits(getMember, VertexShader, name));
		enum location = getUDAs!(__traits(getMember, VertexShader, attribName), Layout)[0].location.value;
	}

	template isVertexAttrib(string member)
	{
		enum isVertexAttrib
			= !hasUDA!(__traits(getMember, VertexShader, member), ignore) 
			&& hasUDA!(__traits(getMember, VertexShader, member), input)
			&& hasUDA!(__traits(getMember, VertexShader, member), Layout)
			;
	}

	alias VertexShader = Filter!(isVertexShader, Shaders)[0];

	enum isVertexShader(S) = S.type == "vertex";
}

GLuint glElementSize(T)()
{
	static if(is(T == Vector!(A,n), A, uint n))
		return n;
	else
		return 1;
}
GLuint glElementType(T)()
{
	static if(is(T == Vector!(A,n), A, uint n))
		return glType!A;
	else
		return glType!T;
}
GLuint glType(T)()
{
	import std.traits;
	import std.algorithm;
	import std.ascii;
	import std.conv;

	enum scalar(U) = `GL_` ~(isUnsigned!U? `UNSIGNED_` ~U.stringof.map!toUpper.text[1..$] : U.stringof.map!toUpper.text);
	enum vector(uint n, U) = scalar!U~ `_VEC` ~n.text;
	enum matrix(uint m, uint n, U) = scalar!U~ `_MAT` ~n.text ~(m == n? `` : `x` ~m.text);

	static if (is (T == Matrix!(U,m,n), uint m, uint n, U))
		return mixin(matrix!(m,n,U));
	else static if (is (T == Vector!(U,n), uint n, U))
		return mixin(vector!(n,U));
	else 
		return mixin(scalar!T);
}



/*
** プログラムの情報を表示する
** from: http://marina.sys.wakayama-u.ac.jp/~tokoi/?date=20090827
*/
string infoLog(T...)(Program!T p)
{
    GLsizei bufSize;

    /* シェーダのリンク時のログの長さを取得する */
    glGetProgramiv(p.id, GL_INFO_LOG_LENGTH , &bufSize);

    if (bufSize == 0) return "";

    GLchar[] infoLog = new GLchar[](bufSize);
    GLsizei length;

    /* シェーダのリンク時のログの内容を取得する */
    glGetProgramInfoLog(p.id, bufSize, &length, infoLog.ptr);
    return format("InfoLog:\n%s\n", infoLog);
}

auto makeProgram(T...)(T shaders) {
    return new Program!T(shaders);
}

import std.typecons;

Tuple!(string, string)[] shader_uniform_list(T: ShaderBase)() {
    import std.traits;
    Tuple!(string, string)[] lst;
    foreach (immutable s; __traits(derivedMembers, T)) {
        static if (!hasUDA!(__traits(getMember, T, s), ignore) && hasUDA!(__traits(getMember, T, s), uniform)) {
            immutable type = typeof(__traits(getMember, T, s)).stringof;
            lst ~= Tuple!(string, string)(s, (type.startsWith("Sampler")) ? "int" : type);
        }
    }
    return lst;
}

Tuple!(string, string)[] shader_uniform_list(T...)() if (T.length > 1) {
    import std.algorithm;
    auto ls = shader_uniform_list!(T[0]);
    auto ls2 = shader_uniform_list!(T[1 .. $]);

    foreach (s; ls) {
        if (!ls2.canFind(s)) ls2 ~= s;
    }

    return ls2;
}


string shader_uniform(T...)() {
    import std.algorithm;
    string result = "";
    auto lst = shader_uniform_list!T;

    foreach (sym; lst) {
        result ~= "GLint %sLoc;\n".format(sym[0]);
        result ~= "@property void %s(%s v) { glUniform(%sLoc, v); }\n".format(sym[0], sym[1], sym[0]);
    }

    auto locs = lst
        .map!(sym => "\t%sLoc = glGetUniformLocation(_programid, `%s`.toStringz);".format(sym[0], sym[0]))
        .join("\n");

    result ~= "void setUniformLocations() {\n" ~ locs ~ "\n}\n";

    return result;
}
